use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tarmac_protocol::Msg;
use tokio::sync::{mpsc, oneshot};
use tracing::debug;

use crate::boards::BoardId;
use crate::proc;
use crate::state::Daemon;

pub const OUTPUT_CHUNK: usize = 64 * 1024; // protocol: output chunks <= 64 KiB
pub(crate) const PROC_POLL_INTERVAL: Duration = Duration::from_millis(750);
const BELL_DEBOUNCE: Duration = Duration::from_millis(250);
const BEL: u8 = 0x07;
// A (re)connecting app replays this to re-bind to a live shell instead of
// cold-spawning. Bounded so N boards x M terms stay cheap.
const SCROLLBACK_CAP: usize = 256 * 1024;

/// A fixed-byte-cap ring of a term's recent pty output, front-evicting.
struct ScrollbackRing {
    buf: VecDeque<u8>,
}

impl ScrollbackRing {
    fn new() -> Self {
        ScrollbackRing { buf: VecDeque::new() }
    }

    fn push(&mut self, bytes: &[u8]) {
        if bytes.len() >= SCROLLBACK_CAP {
            // A single oversize chunk: keep only its trailing cap bytes.
            self.buf.clear();
            self.buf.extend(&bytes[bytes.len() - SCROLLBACK_CAP..]);
            return;
        }
        self.buf.extend(bytes);
        if self.buf.len() > SCROLLBACK_CAP {
            let overflow = self.buf.len() - SCROLLBACK_CAP;
            self.buf.drain(..overflow);
        }
    }

    fn snapshot(&self) -> Vec<u8> {
        self.buf.iter().copied().collect()
    }
}

pub struct TermHandle {
    pub input_tx: mpsc::Sender<Vec<u8>>,
    master: std::sync::Mutex<Box<dyn MasterPty + Send>>,
    // A std::sync::Mutex (not tokio): it is only ever locked for a synchronous
    // push/snapshot, never across .await.
    scrollback: std::sync::Mutex<ScrollbackRing>,
    // Captured at spawn BEFORE the wait thread consumes `child` (process_id() is
    // only valid while we own it). The child is its own process-group leader, so
    // `kill(-pid, ..)` signals the group.
    pid: Option<libc::pid_t>,
    /// The terminal was spawned with a `cmd`: its PTY child is the agent for
    /// every report made in it (spec 2611.0009, D1).
    spawned_with_cmd: bool,
    // `NO_REPORT`, `READ_REPORT` or `UNREAD_REPORT`. Written only under the
    // daemon's `reports` lock, in the step that changes the store; read
    // without it, so that a key or a poll tick with no report costs one load.
    report: AtomicU8,
}

const NO_REPORT: u8 = 0;
const READ_REPORT: u8 = 1;
const UNREAD_REPORT: u8 = 2;

impl TermHandle {
    pub fn pid(&self) -> Option<libc::pid_t> {
        self.pid
    }

    pub fn spawned_with_cmd(&self) -> bool {
        self.spawned_with_cmd
    }

    pub fn has_report(&self) -> bool {
        self.report.load(Ordering::Relaxed) != NO_REPORT
    }

    pub fn unread_report(&self) -> bool {
        self.report.load(Ordering::Relaxed) == UNREAD_REPORT
    }

    pub fn set_report(&self, has: bool, unread: bool) {
        let state = match (has, unread) {
            (false, _) => NO_REPORT,
            (true, false) => READ_REPORT,
            (true, true) => UNREAD_REPORT,
        };
        self.report.store(state, Ordering::Relaxed);
    }

    /// A handle on a pty that no process holds: no pid, no foreground leader.
    #[cfg(test)]
    pub(crate) fn detached() -> Arc<TermHandle> {
        Arc::new(TermHandle {
            input_tx: mpsc::channel(1).0,
            master: std::sync::Mutex::new(native_pty_system().openpty(PtySize::default()).unwrap().master),
            scrollback: std::sync::Mutex::new(ScrollbackRing::new()),
            pid: None,
            spawned_with_cmd: false,
            report: AtomicU8::new(NO_REPORT),
        })
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<(), String> {
        self.master
            .lock()
            .expect("master lock")
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("resize failed: {e}"))
    }

    pub fn scrollback_snapshot(&self) -> Vec<u8> {
        self.scrollback.lock().expect("scrollback lock").snapshot()
    }

    // SIGHUP lets a shell exit cleanly, as on a terminal close. The wait thread
    // and pump then run the normal exit cleanup; kill never touches the daemon's
    // maps itself. A no-op when the pid is unknown.
    pub fn kill(&self) {
        if let Some(pid) = self.pid {
            // SAFETY: kill(2) with a negative pid signals the process group; the
            // only failures (ESRCH for a dead group, EPERM) are benign here.
            unsafe {
                libc::kill(-pid, libc::SIGHUP);
            }
        }
    }

    /// The foreground process-group leader: at a bare prompt the shell, and
    /// while a job runs the job — the pid whose name the card title shows and
    /// whose cwd a new terminal inherits. A poisoned lock yields `None`.
    pub fn foreground_pid(&self) -> Option<libc::pid_t> {
        self.master.lock().ok()?.process_group_leader()
    }
}

fn should_force_utf8_ctype() -> bool {
    force_utf8_ctype_decision(|k| std::env::var_os(k).map(|v| v.to_string_lossy().into_owned()))
}

/// Pure decision for forcing a UTF-8 character locale on a spawned shell.
/// Follows POSIX precedence (`LC_ALL` > `LC_CTYPE` > `LANG`): the first variable
/// that is set and non-empty decides the effective character locale. Returns
/// `false` when that value already selects UTF-8 (leave the user's choice
/// alone), and `true` when it is non-UTF-8 (e.g. `C`) or nothing is set at all
/// (the launchd case that breaks CJK input). `lookup` mirrors `var_os`: `None`
/// means unset.
fn force_utf8_ctype_decision(lookup: impl Fn(&str) -> Option<String>) -> bool {
    for key in ["LC_ALL", "LC_CTYPE", "LANG"] {
        if let Some(v) = lookup(key) {
            if v.is_empty() {
                continue; // POSIX ignores an empty value; fall through.
            }
            let v = v.to_ascii_uppercase();
            return !(v.contains("UTF-8") || v.contains("UTF8"));
        }
    }
    true
}

pub async fn check_free(daemon: &Daemon, term_id: &str) -> Result<(), String> {
    if daemon.terms.lock().await.contains_key(term_id) {
        return Err(format!("term_id already in use: {term_id}"));
    }
    Ok(())
}

/// One terminal to spawn, with its cwd already checked.
pub struct SpawnPlan {
    pub term_id: String,
    pub size: (u16, u16),
    pub cwd: Option<String>,
    pub cmd: Option<Vec<String>>,
    pub board: BoardId,
    /// The persisted terminal whose record this one takes (`Daemon::adopt_term`).
    pub succeeds: Option<String>,
}

pub async fn spawn(daemon: Arc<Daemon>, plan: SpawnPlan) -> Result<(), String> {
    check_free(&daemon, &plan.term_id).await?;
    let (cols, rows) = plan.size;
    let term_id = plan.term_id.clone();
    let cmd = plan.cmd.clone();
    let cwd = plan.cwd.clone();

    let argv = match cmd {
        Some(v) if !v.is_empty() => v,
        Some(_) => return Err("cmd must be a non-empty argv".into()),
        None => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".into());
            vec![shell, "-il".into()]
        }
    };
    let cwd = cwd
        .unwrap_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/".into()));

    let pty = native_pty_system()
        .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| format!("openpty failed: {e}"))?;

    let mut builder = CommandBuilder::new(&argv[0]);
    builder.args(&argv[1..]);
    builder.cwd(cwd);
    builder.env("TERM", "xterm-256color");
    // `tarmac open` inside this pty reads it to attribute the open to its terminal card.
    builder.env("TARMAC_TERM_ID", &term_id);
    // A launchd-launched daemon inherits no LANG/LC_*, so zsh lands in the C
    // locale and its line editor (mbrtowc) mangles the UTF-8 bytes of a CJK/IME
    // commit. Force a UTF-8 character locale only when none is already in effect.
    if should_force_utf8_ctype() {
        builder.env("LC_CTYPE", "en_US.UTF-8");
    }

    let child = pty
        .slave
        .spawn_command(builder)
        .map_err(|e| format!("spawn failed: {e}"))?;
    // Before the wait thread below consumes `child`; see TermHandle::pid.
    let child_pid = child.process_id().map(|p| p as libc::pid_t);
    // Drop the slave or the master reader never sees EOF.
    drop(pty.slave);

    let mut reader = pty
        .master
        .try_clone_reader()
        .map_err(|e| format!("pty reader unavailable: {e}"))?;
    let mut writer = pty
        .master
        .take_writer()
        .map_err(|e| format!("pty writer unavailable: {e}"))?;

    let (input_tx, mut input_rx) = mpsc::channel::<Vec<u8>>(256);
    let handle = Arc::new(TermHandle {
        input_tx,
        master: std::sync::Mutex::new(pty.master),
        scrollback: std::sync::Mutex::new(ScrollbackRing::new()),
        pid: child_pid,
        spawned_with_cmd: plan.cmd.is_some(),
        report: AtomicU8::new(NO_REPORT),
    });
    // Before the loop starts: its first cwd read fills the record of the
    // term's board, which must be there by then.
    daemon.adopt_term(&plan).await;
    daemon.terms.lock().await.insert(term_id.clone(), handle.clone());

    tokio::spawn(proc_loop(daemon.clone(), term_id.clone(), handle.clone()));

    let (out_tx, out_rx) = mpsc::channel::<Vec<u8>>(256);
    tokio::task::spawn_blocking(move || {
        let mut buf = vec![0u8; OUTPUT_CHUNK];
        loop {
            match reader.read(&mut buf) {
                // macOS returns EIO (not Ok(0)) once the child is gone.
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });

    tokio::task::spawn_blocking(move || {
        while let Some(bytes) = input_rx.blocking_recv() {
            if writer.write_all(&bytes).is_err() {
                break;
            }
            let _ = writer.flush();
        }
    });

    let (exit_tx, exit_rx) = oneshot::channel::<Option<i64>>();
    let mut child = child;
    tokio::task::spawn_blocking(move || {
        // A signal death is the protocol's nil exit code; portable-pty forces
        // its code to 1, which must not be trusted.
        let code = match child.wait() {
            Ok(status) => {
                if status.signal().is_some() {
                    None
                } else {
                    Some(status.exit_code() as i64)
                }
            }
            Err(_) => None,
        };
        let _ = exit_tx.send(code);
    });

    tokio::spawn(pump(daemon, term_id, out_rx, exit_rx, handle));
    Ok(())
}

/// Pushes at most one bell per `BELL_DEBOUNCE` window.
struct BellDebounce {
    last: Option<Instant>,
}

impl BellDebounce {
    fn rings(&mut self, chunk: &[u8]) -> bool {
        if !chunk.contains(&BEL) {
            return false;
        }
        let now = Instant::now();
        if self.last.is_none_or(|t| now.duration_since(t) >= BELL_DEBOUNCE) {
            self.last = Some(now);
            return true;
        }
        false
    }
}

// Scanning for BEL here, not in the blocking reader thread, keeps the reader
// free of a daemon handle. Every chunk lands in the scrollback ring even while
// no app is connected.
async fn forward_chunk(
    daemon: &Daemon,
    term_id: &str,
    handle: &TermHandle,
    bells: &mut BellDebounce,
    chunk: Vec<u8>,
) {
    let bell = bells.rings(&chunk);
    // The guard drops at the `;`, before any .await.
    handle.scrollback.lock().expect("scrollback lock").push(&chunk);
    daemon.push(Msg::Output { term_id: term_id.to_owned(), bytes: chunk }).await;
    if bell {
        daemon.push(Msg::Bell { term_id: term_id.to_owned() }).await;
    }
}

// Sends exit only after output is drained, so the app always sees output frames
// before the exit frame.
async fn pump(
    daemon: Arc<Daemon>,
    term_id: String,
    mut out_rx: mpsc::Receiver<Vec<u8>>,
    mut exit_rx: oneshot::Receiver<Option<i64>>,
    handle: Arc<TermHandle>,
) {
    let mut bells = BellDebounce { last: None };
    let mut exit_code: Option<Option<i64>> = None;
    loop {
        if exit_code.is_some() {
            // Child is gone; drain whatever output remains, with a grace cap
            // in case a grandchild still holds the pty open.
            match tokio::time::timeout(Duration::from_secs(2), out_rx.recv()).await {
                Ok(Some(chunk)) => forward_chunk(&daemon, &term_id, &handle, &mut bells, chunk).await,
                _ => break,
            }
        } else {
            tokio::select! {
                maybe = out_rx.recv() => match maybe {
                    Some(chunk) => forward_chunk(&daemon, &term_id, &handle, &mut bells, chunk).await,
                    None => {
                        exit_code = Some((&mut exit_rx).await.unwrap_or(None));
                        break;
                    }
                },
                code = &mut exit_rx => {
                    exit_code = Some(code.unwrap_or(None));
                }
            }
        }
    }
    let code = exit_code.flatten();
    debug!("term {term_id} exited with {code:?}");
    daemon.term_ended(&term_id, code).await;
    daemon.push(Msg::Exit { term_id, code }).await;
    // The exited pty lowered its board's running count; re-push so a switcher
    // row, even for a board the app has not rebuilt, drops it.
    daemon.push(daemon.board_list_msg().await).await;
}

// Pushes a `term_proc` whenever the foreground process name changes (and once
// on the first resolve), and records the cwd whenever the foreground pid
// changes (and once for the first pid): an idle terminal makes no cwd read.
// Stops when the pump removes the term after exit. Any lookup or lock failure
// skips the tick; this loop never panics.
async fn proc_loop(daemon: Arc<Daemon>, term_id: String, handle: Arc<TermHandle>) {
    let mut last_name: Option<String> = None;
    let mut last_pid: Option<libc::pid_t> = None;
    let mut ticker = tokio::time::interval(PROC_POLL_INTERVAL);
    loop {
        ticker.tick().await;
        if !daemon.terms.lock().await.contains_key(&term_id) {
            break;
        }
        let leader = handle.foreground_pid();
        // Before the `continue` on a failed leader read: an agent's exit must
        // end its report all the same.
        daemon.check_report(&term_id, &handle, leader).await;

        let Some(pid) = leader else { continue };
        if let Some(name) = proc::process_name(pid)
            && last_name.as_deref() != Some(name.as_str())
        {
            last_name = Some(name.clone());
            daemon
                .push(Msg::TermProc { term_id: term_id.clone(), name, pid: Some(pid as i64) })
                .await;
        }
        if last_pid != Some(pid) {
            last_pid = Some(pid);
            daemon.note_cwd(&term_id, pid).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn decide(pairs: &[(&str, &str)]) -> bool {
        let env: HashMap<&str, &str> = pairs.iter().copied().collect();
        force_utf8_ctype_decision(|k| env.get(k).map(|v| v.to_string()))
    }

    #[test]
    fn forces_utf8_when_nothing_is_set() {
        // The launchd-launched daemon case: no locale vars at all.
        assert!(decide(&[]));
    }

    #[test]
    fn forces_utf8_when_effective_locale_is_non_utf8() {
        assert!(decide(&[("LANG", "C")]));
        assert!(decide(&[("LC_ALL", "POSIX")]));
        assert!(decide(&[("LC_CTYPE", "en_US.ISO8859-1")]));
    }

    #[test]
    fn leaves_an_existing_utf8_locale_alone() {
        assert!(!decide(&[("LANG", "en_US.UTF-8")]));
        assert!(!decide(&[("LC_CTYPE", "zh_TW.UTF-8")]));
        assert!(!decide(&[("LC_ALL", "en_US.utf8")])); // case/dash-insensitive
    }

    #[test]
    fn respects_posix_precedence_lc_all_over_lang() {
        // LC_ALL wins: a UTF-8 LC_ALL keeps us out even with a C LANG…
        assert!(!decide(&[("LC_ALL", "en_US.UTF-8"), ("LANG", "C")]));
        // …and a non-UTF-8 LC_ALL forces, even with a UTF-8 LANG.
        assert!(decide(&[("LC_ALL", "C"), ("LANG", "en_US.UTF-8")]));
    }

    #[test]
    fn empty_value_falls_through_to_next_key() {
        assert!(!decide(&[("LC_ALL", ""), ("LANG", "en_US.UTF-8")]));
        assert!(decide(&[("LC_CTYPE", ""), ("LANG", "C")]));
    }

    // The exit goes first and the pump takes it before any chunk exists, so the
    // chunks can leave only through the drain branch. With both queued up front,
    // `select!` picks at random and the drain branch can stay unused.
    #[tokio::test]
    async fn output_queued_behind_the_exit_precedes_the_exit_frame() {
        let state = std::env::temp_dir().join(format!("tarmac-term-pump-{}", std::process::id())).join("state.json");
        let daemon = Daemon::new(state).await.unwrap();
        let (app_tx, mut app_rx) = mpsc::channel(8);
        daemon.install_app(app_tx, None).await;
        let handle = TermHandle::detached();
        let (out_tx, out_rx) = mpsc::channel(2);
        let (exit_tx, exit_rx) = oneshot::channel();
        let pump = tokio::spawn(pump(daemon, "t1".into(), out_rx, exit_rx, handle));

        exit_tx.send(Some(0)).unwrap();
        tokio::task::yield_now().await;
        out_tx.send(b"last ".to_vec()).await.unwrap();
        out_tx.send(b"words".to_vec()).await.unwrap();
        drop(out_tx);
        pump.await.unwrap();

        let frames: Vec<Msg> = std::iter::from_fn(|| app_rx.try_recv().ok()).take(3).collect();
        assert_eq!(frames, vec![
            Msg::Output { term_id: "t1".into(), bytes: b"last ".to_vec() },
            Msg::Output { term_id: "t1".into(), bytes: b"words".to_vec() },
            Msg::Exit { term_id: "t1".into(), code: Some(0) },
        ]);
    }
}
