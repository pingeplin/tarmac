use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::Arc;
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tarmac_protocol::Msg;
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, warn};

use crate::proc;
use crate::state::Daemon;

pub const OUTPUT_CHUNK: usize = 64 * 1024; // protocol: output chunks <= 64 KiB
const PROC_POLL_INTERVAL: Duration = Duration::from_millis(750);
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
}

impl TermHandle {
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

    /// The foreground process-group leader. A poisoned lock yields `None`.
    fn foreground_pid(&self) -> Option<libc::pid_t> {
        self.master.lock().ok()?.process_group_leader()
    }

    /// The CURRENT working directory of the foreground job's leader (never the
    /// spawn-time cwd): at a bare prompt that leader is the shell, and while a
    /// job runs it is the job — the same pid whose name the card title shows.
    /// `master` is locked only for the pid read, so this is safe in an async
    /// handler. `None` when the pty or the OS lookup does not resolve.
    pub fn live_cwd(&self) -> Option<String> {
        proc::pid_cwd(self.foreground_pid()?)
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

pub async fn spawn(
    daemon: Arc<Daemon>,
    term_id: String,
    cols: u16,
    rows: u16,
    cwd: Option<String>,
    cmd: Option<Vec<String>>,
) -> Result<(), String> {
    if daemon.terms.lock().await.contains_key(&term_id) {
        return Err(format!("term_id already in use: {term_id}"));
    }

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
    });
    daemon.terms.lock().await.insert(term_id.clone(), handle.clone());

    tokio::spawn(proc_name_loop(daemon.clone(), term_id.clone(), handle.clone()));

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
    if daemon.terms.lock().await.remove(&term_id).is_none() {
        warn!("term {term_id} missing from registry at exit");
    }
    daemon.term_boards.lock().await.remove(&term_id);
    daemon.push(Msg::Exit { term_id, code }).await;
    // The exited pty lowered its board's running count; re-push so a switcher
    // row, even for a board the app has not rebuilt, drops it.
    daemon.push(daemon.board_list_msg().await).await;
}

// Pushes a `term_proc` whenever the foreground process name changes (and once
// on the first resolve). Stops when the pump removes the term after exit. Any
// lookup or lock failure skips the tick; this loop never panics.
async fn proc_name_loop(daemon: Arc<Daemon>, term_id: String, handle: Arc<TermHandle>) {
    let mut last_name: Option<String> = None;
    let mut ticker = tokio::time::interval(PROC_POLL_INTERVAL);
    loop {
        ticker.tick().await;
        if !daemon.terms.lock().await.contains_key(&term_id) {
            break;
        }

        let Some(pid) = handle.foreground_pid() else { continue };
        let Some(name) = proc::process_name(pid) else { continue };

        if last_name.as_deref() != Some(name.as_str()) {
            last_name = Some(name.clone());
            daemon
                .push(Msg::TermProc { term_id: term_id.clone(), name, pid: Some(pid as i64) })
                .await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::force_utf8_ctype_decision;
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
        // An empty higher-precedence var is ignored; the next decides.
        assert!(!decide(&[("LC_ALL", ""), ("LANG", "en_US.UTF-8")]));
        assert!(decide(&[("LC_CTYPE", ""), ("LANG", "C")]));
    }
}
