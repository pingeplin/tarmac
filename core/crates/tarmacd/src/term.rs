use std::collections::VecDeque;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tarmac_protocol::Msg;
use tokio::sync::{mpsc, oneshot};
use tracing::debug;

use crate::bell_scan::Bells;
use crate::boards::BoardId;
use crate::holder::{Holder, StartedPid};
use crate::proc;
use crate::reader::PathGate;
use crate::resume::Flag;
use crate::state::Daemon;

pub(crate) const OUTPUT_CHUNK: usize = 64 * 1024; // protocol: output chunks <= 64 KiB
pub(crate) const PROC_POLL_INTERVAL: Duration = Duration::from_millis(750);
/// How often a held input reads the pty's termios (spec 2611.0016, D11).
const HOLD_POLL: Duration = Duration::from_millis(20);
/// How long a held input waits for the shell to take keys.
pub(crate) const HOLD_DEADLINE: Duration = Duration::from_secs(10);
/// The longest canonical line the typeahead probe saw arrive whole: macOS
/// keeps 1024 bytes of one and drops the rest, `\r` included, with no error.
const HOLD_CANON_SAFE: usize = 1000;
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

/// One write to a terminal's pty, in the order the app sent it.
pub(crate) struct Input {
    pub bytes: Vec<u8>,
    /// Written once the shell takes keys (`hold`).
    pub hold: bool,
}

/// What the pty's line discipline says of a held input's terminal.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Keys {
    /// ICANON is off: a line editor, or a program in raw mode, reads keys.
    Taken,
    /// Canonical, or the termios could not be read.
    Canonical,
    /// The terminal is gone.
    Ended,
}

fn keys_of(master: &dyn MasterPty) -> Keys {
    match master.get_termios() {
        Some(t) if t.local_flags.bits() & libc::ICANON == 0 => Keys::Taken,
        _ => Keys::Canonical,
    }
}

/// The pty writer's loop: each input in turn. A held one waits until the
/// shell takes keys; at `deadline` a still-canonical tty gets it only when it
/// is at most `HOLD_CANON_SAFE` bytes, since a cut line would wait at the
/// prompt for a Return. Input sent after a held one waits too. While one is
/// held, the channel is drained into the writer's own queue, so the app
/// connection's dispatch does not wait on a hold. Outside a hold the inputs
/// stay in the bounded channel: while `write_all` blocks on a full pty, the
/// channel can fill and the dispatch waits, as it always did. `dropped` is
/// told of each held input that is not written; a terminal that ends ends the
/// loop.
fn write_inputs(
    mut input_rx: mpsc::Receiver<Input>,
    mut writer: impl Write,
    deadline: Duration,
    mut keys: impl FnMut() -> Keys,
    mut dropped: impl FnMut(),
) {
    let mut queue = VecDeque::new();
    loop {
        let Some(input) = queue.pop_front().or_else(|| input_rx.blocking_recv()) else { return };
        if input.hold {
            let since = Instant::now();
            let write = loop {
                while let Ok(next) = input_rx.try_recv() {
                    queue.push_back(next);
                }
                match keys() {
                    Keys::Taken => break true,
                    Keys::Ended => return,
                    Keys::Canonical if since.elapsed() >= deadline => break input.bytes.len() <= HOLD_CANON_SAFE,
                    Keys::Canonical => std::thread::sleep(HOLD_POLL),
                }
            };
            if !write {
                dropped();
                continue;
            }
        }
        if writer.write_all(&input.bytes).is_err() {
            return;
        }
        let _ = writer.flush();
    }
}

pub(crate) struct TermHandle {
    pub input_tx: mpsc::Sender<Input>,
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
    // A `resume::Flag`, and the holder of the resume command.
    // Both are written only under the daemon's `boards` lock, in the step
    // that changes the record; the flag is read without it, so a key or a
    // poll tick with no command costs one load. The holder's lock is taken
    // after `boards`, never across an await.
    resume: AtomicU8,
    resume_holder: std::sync::Mutex<Option<StartedPid>>,
}

const NO_REPORT: u8 = 0;
const READ_REPORT: u8 = 1;
const UNREAD_REPORT: u8 = 2;

impl TermHandle {
    fn new(
        input_tx: mpsc::Sender<Input>,
        master: Box<dyn MasterPty + Send>,
        pid: Option<proc::Pid>,
        spawned_with_cmd: bool,
    ) -> Arc<TermHandle> {
        Arc::new(TermHandle {
            input_tx,
            master: std::sync::Mutex::new(master),
            scrollback: std::sync::Mutex::new(ScrollbackRing::new()),
            pid,
            spawned_with_cmd,
            report: AtomicU8::new(NO_REPORT),
            resume: AtomicU8::new(Flag::None as u8),
            resume_holder: std::sync::Mutex::new(None),
        })
    }

    /// The process a `report` or a `resume` from `peer` is tied to.
    pub(crate) fn resolve_holder(&self, peer: Option<proc::Pid>) -> Option<Holder> {
        Holder::resolve(peer, self.pid, self.spawned_with_cmd, proc::proc_facts, || self.foreground_pid())
    }

    pub(crate) fn has_report(&self) -> bool {
        self.report.load(Ordering::Relaxed) != NO_REPORT
    }

    pub(crate) fn unread_report(&self) -> bool {
        self.report.load(Ordering::Relaxed) == UNREAD_REPORT
    }

    pub(crate) fn set_report(&self, has: bool, unread: bool) {
        let state = match (has, unread) {
            (false, _) => NO_REPORT,
            (true, false) => READ_REPORT,
            (true, true) => UNREAD_REPORT,
        };
        self.report.store(state, Ordering::Relaxed);
    }

    pub(crate) fn resume_flag(&self) -> Flag {
        Flag::from_u8(self.resume.load(Ordering::Relaxed))
    }

    pub(crate) fn resume_holder(&self) -> Option<StartedPid> {
        *self.resume_holder.lock().expect("resume holder lock")
    }

    /// A command with `holder`.
    pub(crate) fn hold_resume(&self, holder: StartedPid) {
        *self.resume_holder.lock().expect("resume holder lock") = Some(holder);
        self.resume.store(Flag::Held as u8, Ordering::Relaxed);
    }

    /// A command with no holder.
    pub(crate) fn unclaim_resume(&self) {
        *self.resume_holder.lock().expect("resume holder lock") = None;
        self.resume.store(Flag::Unclaimed as u8, Ordering::Relaxed);
    }

    pub(crate) fn forget_resume(&self) {
        *self.resume_holder.lock().expect("resume holder lock") = None;
        self.resume.store(Flag::None as u8, Ordering::Relaxed);
    }

    /// A handle on a pty that no process holds: no pid, no foreground leader.
    #[cfg(test)]
    pub(crate) fn detached() -> Arc<TermHandle> {
        TermHandle::new(
            mpsc::channel(1).0,
            native_pty_system().openpty(PtySize::default()).unwrap().master,
            None,
            false,
        )
    }

    pub(crate) fn resize(&self, cols: u16, rows: u16) -> Result<(), String> {
        self.master
            .lock()
            .expect("master lock")
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| format!("resize failed: {e}"))
    }

    /// The master lock is held for the one read.
    fn keys(&self) -> Keys {
        self.master.lock().map_or(Keys::Canonical, |m| keys_of(&**m))
    }

    pub(crate) fn scrollback_snapshot(&self) -> Vec<u8> {
        self.scrollback.lock().expect("scrollback lock").snapshot()
    }

    // SIGHUP lets a shell exit cleanly, as on a terminal close. The wait thread
    // and pump then run the normal exit cleanup; kill never touches the daemon's
    // maps itself. A no-op when the pid is unknown.
    pub(crate) fn kill(&self) {
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
    pub(crate) fn foreground_pid(&self) -> Option<libc::pid_t> {
        self.master.lock().ok()?.process_group_leader()
    }

    /// The foreground pid and its cwd, read on `gate`: a cwd on a volume
    /// that is gone does not answer. The cwd is `None` when the read is out
    /// or gives nothing.
    pub(crate) async fn foreground_read(&self, gate: &PathGate) -> Option<(proc::Pid, Option<String>)> {
        let pid = self.foreground_pid()?;
        Some((pid, gate.pid_cwd(pid).await.ok().flatten()))
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

pub(crate) async fn check_free(daemon: &Daemon, term_id: &str) -> Result<(), String> {
    if daemon.terms.lock().await.contains_key(term_id) {
        return Err(format!("term_id already in use: {term_id}"));
    }
    Ok(())
}

/// One terminal to spawn, with its cwd already checked.
pub(crate) struct SpawnPlan {
    pub term_id: String,
    pub size: (u16, u16),
    pub cwd: Option<String>,
    pub cmd: Option<Vec<String>>,
    pub board: BoardId,
    /// The persisted terminal whose record this one takes (`Daemon::adopt_term`).
    pub succeeds: Option<String>,
}

pub(crate) async fn spawn(daemon: Arc<Daemon>, plan: SpawnPlan) -> Result<(), String> {
    spawn_holding(daemon, plan, HOLD_DEADLINE).await
}

/// `spawn`, whose held inputs wait at most `hold_deadline`.
pub(crate) async fn spawn_holding(daemon: Arc<Daemon>, plan: SpawnPlan, hold_deadline: Duration) -> Result<(), String> {
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
    let cwd = cwd.unwrap_or_else(|| std::env::var("HOME").unwrap_or_else(|_| "/".into()));

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

    let child = pty.slave.spawn_command(builder).map_err(|e| format!("spawn failed: {e}"))?;
    // Before the wait thread below consumes `child`; see TermHandle::pid.
    #[expect(clippy::cast_possible_wrap, reason = "a pid_t that std cast to u32: casting back is exact")]
    let child_pid = child.process_id().map(|p| p as libc::pid_t);
    // Drop the slave or the master reader never sees EOF.
    drop(pty.slave);

    let mut reader = pty.master.try_clone_reader().map_err(|e| format!("pty reader unavailable: {e}"))?;
    let writer = pty.master.take_writer().map_err(|e| format!("pty writer unavailable: {e}"))?;

    let (input_tx, input_rx) = mpsc::channel::<Input>(256);
    let handle = TermHandle::new(input_tx, pty.master, child_pid, plan.cmd.is_some());
    // Before the loop starts: its first cwd read fills the record of the
    // term's board, which must be there by then.
    daemon.adopt_term(&plan, &handle).await;
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

    // Weak: the handle owns `input_tx`, and a strong one here would keep the
    // channel, and this thread, open after the terminal ends.
    let weak: Weak<TermHandle> = Arc::downgrade(&handle);
    let keys = move || weak.upgrade().map_or(Keys::Ended, |h| h.keys());
    // Weak too: the daemon holds the handle, so a strong one would be a cycle.
    let runtime = tokio::runtime::Handle::current();
    let (notice, dropped_id) = (Arc::downgrade(&daemon), term_id.clone());
    let dropped = move || {
        let msg = format!("input held for {dropped_id} dropped: the shell did not take keys");
        tracing::warn!("{msg}");
        if let Some(daemon) = notice.upgrade() {
            runtime.block_on(daemon.push(Msg::Err { msg }));
        }
    };
    tokio::task::spawn_blocking(move || write_inputs(input_rx, writer, hold_deadline, keys, dropped));

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
                    Some(i64::from(status.exit_code()))
                }
            }
            Err(_) => None,
        };
        let _ = exit_tx.send(code);
    });

    tokio::spawn(pump(daemon, term_id, out_rx, exit_rx, handle));
    Ok(())
}

// Scanning for BEL here, not in the blocking reader thread, keeps the reader
// free of a daemon handle. Every chunk lands in the scrollback ring even while
// no app is connected.
async fn forward_chunk(daemon: &Daemon, term_id: &str, handle: &TermHandle, bells: &mut Bells, chunk: Vec<u8>) {
    let bell = bells.rings(&chunk, Instant::now());
    // The guard drops at the `;`, before any .await.
    handle.scrollback.lock().expect("scrollback lock").push(&chunk);
    daemon.push(Msg::Output { term_id: term_id.to_owned(), bytes: chunk }).await;
    if bell {
        let board_id = daemon.term_boards.lock().await.get(term_id).cloned();
        daemon.emit(Msg::Bell { term_id: term_id.to_owned(), board_id }).await;
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
    let mut bells = Bells::default();
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
                maybe = out_rx.recv() => if let Some(chunk) = maybe { forward_chunk(&daemon, &term_id, &handle, &mut bells, chunk).await } else {
                    exit_code = Some((&mut exit_rx).await.unwrap_or(None));
                    break;
                },
                code = &mut exit_rx => {
                    exit_code = Some(code.unwrap_or(None));
                }
            }
        }
    }
    let code = exit_code.flatten();
    debug!("term {term_id} exited with {code:?}");
    let board_id = daemon.term_ended(&term_id, code).await;
    daemon.emit(Msg::Exit { term_id, code, board_id }).await;
    // The exited pty lowered its board's running count; re-push so a switcher
    // row, even for a board the app has not rebuilt, drops it.
    daemon.push(daemon.board_list_msg().await).await;
}

// Pushes a `term_proc` whenever the foreground process name changes (and once
// on the first resolve), and records the cwd whenever the foreground pid
// changes (and once for the first pid): an idle terminal makes no cwd read.
// Stops when the pump removes the term after exit. Any lookup or lock failure
// skips the tick; this loop never panics.
pub(crate) async fn proc_loop(daemon: Arc<Daemon>, term_id: String, handle: Arc<TermHandle>) {
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
        // end its report and its resume command all the same.
        daemon.check_report(&term_id, &handle, leader).await;
        daemon.check_resume(&term_id, &handle, proc::proc_facts).await;

        let Some(pid) = leader else { continue };
        if let Some(name) = proc::process_name(pid)
            && last_name.as_deref() != Some(name.as_str())
        {
            last_name = Some(name.clone());
            daemon.push(Msg::TermProc { term_id: term_id.clone(), name, pid: Some(i64::from(pid)) }).await;
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
        force_utf8_ctype_decision(|k| env.get(k).map(ToString::to_string))
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

    /// A shell that never leaves canonical mode, reading one line into `out`.
    fn canonical_child(
        out: &std::path::Path,
    ) -> (Box<dyn MasterPty + Send>, Box<dyn portable_pty::Child + Send + Sync>) {
        let pair = native_pty_system().openpty(PtySize::default()).unwrap();
        let mut cmd = CommandBuilder::new("/bin/sh");
        cmd.args(["-c", &format!("head -n 1 > '{}'", out.display())]);
        let child = pair.slave.spawn_command(cmd).unwrap();
        (pair.master, child)
    }

    /// Runs the writer over one held input of `n` `y`s and a `\r` with a
    /// 300 ms deadline: how long it took, how many inputs it dropped, and the
    /// pty's writer, whose drop would write an EOF line. Each read of the keys
    /// before the deadline is followed by a sleep of at least `HOLD_POLL`, so
    /// a writer that reads them more often than that allows never decides.
    fn hold_past_the_deadline(master: &(dyn MasterPty + Send), n: usize) -> (Duration, usize, Box<dyn Write + Send>) {
        let (tx, rx) = mpsc::channel(1);
        tx.try_send(Input { bytes: format!("{}\r", "y".repeat(n)).into_bytes(), hold: true }).unwrap();
        drop(tx);
        let mut writer = master.take_writer().unwrap();
        let mut dropped = 0;
        let (mut reads, most) = (0, 300 / HOLD_POLL.as_millis() + 1);
        let keys = || {
            reads += 1;
            assert!(reads <= most, "the keys were read {reads} times");
            keys_of(master)
        };
        let started = Instant::now();
        write_inputs(rx, &mut writer, Duration::from_millis(300), keys, || dropped += 1);
        (started.elapsed(), dropped, writer)
    }

    #[test]
    fn a_held_input_with_no_time_left_is_decided_at_the_first_read_of_the_keys() {
        let (tx, rx) = mpsc::channel(1);
        tx.try_send(Input { bytes: b"ls\r".to_vec(), hold: true }).unwrap();
        drop(tx);
        let (mut reads, mut written) = (0, Vec::new());
        let keys = || {
            reads += 1;
            assert_eq!(reads, 1, "the keys were read again");
            Keys::Canonical
        };

        write_inputs(rx, &mut written, Duration::ZERO, keys, || panic!("a short input is not dropped"));

        assert_eq!(written, b"ls\r");
    }

    // architecture.md: a term's scrollback ring keeps its last 256 KiB.
    const RING_BYTES: usize = 256 * 1024;

    fn output_of(len: usize) -> Vec<u8> {
        (0..len).map(|i| u8::try_from(i % 251).unwrap()).collect()
    }

    #[test]
    fn the_scrollback_keeps_the_last_256_kib_of_the_output() {
        let output = output_of(RING_BYTES + 5000);
        let mut ring = ScrollbackRing::new();
        for chunk in output.chunks(1000) {
            ring.push(chunk);
        }
        assert!(ring.snapshot() == output[5000..], "{} bytes kept", ring.snapshot().len());
    }

    #[test]
    fn a_chunk_longer_than_the_scrollback_keeps_its_last_256_kib() {
        let output = output_of(RING_BYTES + 5000);
        let mut ring = ScrollbackRing::new();
        ring.push(b"before");
        ring.push(&output);
        assert!(ring.snapshot() == output[5000..], "{} bytes kept", ring.snapshot().len());
    }

    #[test]
    fn a_report_flag_tells_no_report_a_read_one_and_an_unread_one() {
        let handle = TermHandle::detached();
        assert!(!handle.has_report() && !handle.unread_report(), "a new terminal");
        handle.set_report(true, false);
        assert!(handle.has_report() && !handle.unread_report(), "a read report");
        handle.set_report(true, true);
        assert!(handle.has_report() && handle.unread_report(), "an unread report");
        handle.set_report(false, false);
        assert!(!handle.has_report() && !handle.unread_report(), "no report");
    }

    #[test]
    fn a_forgotten_resume_command_leaves_no_flag_and_no_holder() {
        let handle = TermHandle::detached();
        handle.hold_resume(StartedPid { pid: 200, started: 11 });

        handle.forget_resume();

        assert_eq!(handle.resume_flag(), Flag::None);
        assert_eq!(handle.resume_holder(), None);
    }

    fn read_within(out: &std::path::Path, wait: Duration) -> String {
        let deadline = Instant::now() + wait;
        loop {
            let got = std::fs::read_to_string(out).unwrap_or_default();
            if !got.is_empty() || Instant::now() >= deadline {
                return got;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    // "Held input deadline sends small and refuses large": HOLD_DEADLINE set short.
    #[test]
    fn a_short_held_input_is_written_at_the_deadline_to_a_canonical_child() {
        let dir = crate::fixtures::tmp_dir("hold-short");
        let out = dir.join("out");
        let (master, mut child) = canonical_child(&out);

        let (took, dropped, _writer) = hold_past_the_deadline(&*master, 999);

        assert!(took >= Duration::from_millis(300), "written after {took:?}");
        assert_eq!(dropped, 0);
        assert_eq!(read_within(&out, Duration::from_secs(5)), format!("{}\n", "y".repeat(999)));
        let _ = child.kill();
        let _ = std::fs::remove_dir_all(&dir);
    }

    // "Held input deadline sends small and refuses large"
    #[test]
    fn a_held_input_over_1000_bytes_is_dropped_at_the_deadline_with_one_notice() {
        let dir = crate::fixtures::tmp_dir("hold-long");
        let out = dir.join("out");
        let (master, mut child) = canonical_child(&out);

        let (_, dropped, _writer) = hold_past_the_deadline(&*master, 1000);

        assert_eq!(dropped, 1);
        assert_eq!(read_within(&out, Duration::from_millis(500)), "");
        let _ = child.kill();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_held_input_whose_terminal_ends_is_not_written_and_ends_the_writer() {
        let (tx, rx) = mpsc::channel(2);
        tx.try_send(Input { bytes: b"a\r".to_vec(), hold: true }).unwrap();
        tx.try_send(Input { bytes: b"b".to_vec(), hold: false }).unwrap();
        let mut written = Vec::new();

        write_inputs(rx, &mut written, HOLD_DEADLINE, || Keys::Ended, || panic!("no notice for an ended terminal"));

        assert!(written.is_empty());
    }

    /// A pty writer that notes, at each write, how many of the channel's
    /// slots are free, and fails at the third so the loop ends.
    struct SlotsAtWrite {
        tx: mpsc::Sender<Input>,
        free: Arc<std::sync::Mutex<Vec<usize>>>,
    }

    impl Write for SlotsAtWrite {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let mut free = self.free.lock().unwrap();
            free.push(self.tx.capacity());
            if free.len() == 3 { Err(std::io::ErrorKind::BrokenPipe.into()) } else { Ok(buf.len()) }
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    // Outside a hold the inputs wait in the bounded channel, not in the
    // writer's queue: the channel's back-pressure bounds a stuck pty's memory.
    #[test]
    fn with_no_hold_the_writer_takes_one_input_at_a_time_from_the_channel() {
        let (tx, rx) = mpsc::channel(4);
        for byte in [b"a", b"b", b"c"] {
            tx.try_send(Input { bytes: byte.to_vec(), hold: false }).unwrap();
        }
        let free = Arc::new(std::sync::Mutex::new(Vec::new()));
        let writer = SlotsAtWrite { tx, free: free.clone() };

        write_inputs(rx, writer, HOLD_DEADLINE, || Keys::Taken, || {});

        assert_eq!(*free.lock().unwrap(), vec![2, 3, 4]);
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
        assert_eq!(
            frames,
            vec![
                Msg::Output { term_id: "t1".into(), bytes: b"last ".to_vec() },
                Msg::Output { term_id: "t1".into(), bytes: b"words".to_vec() },
                Msg::Exit { term_id: "t1".into(), code: Some(0), board_id: None },
            ]
        );
    }
}
