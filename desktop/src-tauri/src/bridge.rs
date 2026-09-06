//! The daemon socket bridge — the Rust half of what `DaemonClient.swift` +
//! `Reconnect.swift` + `DaemonLaunch.swift` did in the Swift app. It owns ONE
//! Unix-stream connection to `tarmacd`, speaks the length-prefixed-MessagePack
//! protocol via the reused `tarmac-protocol` crate, and bridges daemon `Msg`s to
//! the web frontend:
//!   - high-volume PTY `Output` → a per-terminal binary Tauri Channel (no JSON);
//!   - everything else → a JSON `"daemon"` event the frontend `listen`s for;
//!   - frontend → daemon: commands (see `commands.rs`) push `Msg`s onto `tx`.
//!
//! The wire codec, framing, conformance, and channel-path derivation all come
//! from `core/`'s `tarmac-protocol` (path dep) — reused, never re-ported.

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::OsString;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tarmac_protocol::{
    check_socket_path_len, decode, encode, frame, resolve_socket_path, Channel as WireChannel,
    Msg, PROTOCOL_VERSION,
};
use tauri::ipc::{Channel as IpcChannel, InvokeResponseBody};
use tauri::{AppHandle, Emitter, Manager};
use tokio::net::UnixStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

/// Per-terminal scrollback byte cap: 256 KiB, matching ~5000 lines of output.
/// Oldest chunks are evicted when a term's buffer would exceed this.
const BUFFER_CAP_BYTES: usize = 256 * 1024;

/// Shared bridge state, managed by Tauri (`app.manage`). Commands look it up via
/// `State<Bridge>`; the connection task looks it up via `app.state::<Bridge>()`.
pub struct Bridge {
    /// Outbound queue to the daemon. Commands push here; the connection task
    /// drains it and frames each `Msg` onto the socket. Unbounded so a brief
    /// disconnect buffers rather than blocks the UI thread.
    tx: UnboundedSender<Msg>,
    /// Per-terminal binary output sinks the frontend registers via `term_attach`.
    outputs: Mutex<HashMap<String, IpcChannel<InvokeResponseBody>>>,
    /// Scrollback buffer: bytes that arrived before `term_attach` was called.
    /// Bounded per-term at `BUFFER_CAP_BYTES`; oldest chunks evicted on overflow.
    /// NOT cleared on `detach_output` — a transient detach+reattach still delivers.
    /// Cleared on `attach_output` after draining (delivery guarantees order).
    buffers: Mutex<HashMap<String, VecDeque<Vec<u8>>>>,
    // The Rust setup hook connects to the daemon BEFORE the webview's JS mounts,
    // so the connection's first status/board_list/restore are emitted with no
    // listener yet. We remember the latest of each (the daemon's authoritative
    // current state) and replay them when the frontend signals it is ready — which
    // also makes a dev HMR reload re-sync cleanly.
    last_status: Mutex<Option<serde_json::Value>>,
    last_board_list: Mutex<Option<serde_json::Value>>,
    // The latest `restore` per board_id. The daemon sends a restore for the active
    // board on connect and for each board as it's visited; remembering ALL of them
    // (not just the last) lets a webview reload / HMR replay rehydrate every board
    // that was visited this session, not only the most-recent one.
    last_restores: Mutex<HashMap<String, serde_json::Value>>,
    /// The spawned daemon child. Retained so we can SIGTERM it on version
    /// mismatch, and so the spawn decision can observe whether it is still alive.
    daemon_child: Mutex<Option<std::process::Child>>,
}

impl Bridge {
    pub fn new(tx: UnboundedSender<Msg>) -> Self {
        Self {
            tx,
            outputs: Mutex::new(HashMap::new()),
            buffers: Mutex::new(HashMap::new()),
            last_status: Mutex::new(None),
            last_board_list: Mutex::new(None),
            last_restores: Mutex::new(HashMap::new()),
            daemon_child: Mutex::new(None),
        }
    }

    fn remember_status(&self, value: serde_json::Value) {
        *self.last_status.lock().unwrap() = Some(value);
    }

    fn remember_msg(&self, tag: &str, value: &serde_json::Value) {
        match tag {
            "board_list" => {
                // Drop remembered restores for boards no longer in the list so a
                // deleted board can't resurrect on a later replay.
                if let Some(boards) = value.get("boards").and_then(|b| b.as_array()) {
                    let ids: HashSet<&str> = boards
                        .iter()
                        .filter_map(|b| b.get("board_id").and_then(|v| v.as_str()))
                        .collect();
                    self.last_restores
                        .lock()
                        .unwrap()
                        .retain(|k, _| ids.contains(k.as_str()));
                }
                *self.last_board_list.lock().unwrap() = Some(value.clone());
            }
            "restore" => {
                // Key by board_id (empty string for a board_id-less single-board
                // daemon) so each board's latest restore is remembered separately.
                let bid = value
                    .get("board_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                self.last_restores.lock().unwrap().insert(bid, value.clone());
            }
            _ => {}
        }
    }

    /// Re-emit the remembered status + current board/restore so a freshly-mounted
    /// (or reloaded) frontend gets the state it may have missed on connect.
    pub fn replay(&self, app: &AppHandle) {
        if let Some(s) = self.last_status.lock().unwrap().clone() {
            let _ = app.emit("daemon-status", s);
        }
        if let Some(b) = self.last_board_list.lock().unwrap().clone() {
            let _ = app.emit("daemon", b);
        }
        // Replay every remembered board's restore (board_list emitted first above,
        // so the frontend has the board set before the per-board cards arrive).
        for r in self.last_restores.lock().unwrap().values() {
            let _ = app.emit("daemon", r.clone());
        }
    }

    /// Enqueue a message for the daemon (fire-and-forget; the protocol has no
    /// request ids). Dropping the receiver only happens at shutdown.
    pub fn send(&self, msg: Msg) {
        let _ = self.tx.send(msg);
    }

    pub fn attach_output(&self, term_id: String, channel: IpcChannel<InvokeResponseBody>) {
        // Hold `outputs` across insert + buffer-drain + send so the
        // channel-presence decision is atomic against `dispatch` (which also
        // locks `outputs` before touching `buffers`). Otherwise a live byte
        // arriving between the insert and the drain could be sent ahead of the
        // replayed scrollback — out-of-order delivery, the very race this buffer
        // exists to prevent. Lock order is always outputs → buffers.
        let mut outputs = self.outputs.lock().unwrap();
        outputs.insert(term_id.clone(), channel);
        // Drain under the buffers lock (released at the `;`), then send while
        // still holding `outputs` so no later dispatch can interleave ahead.
        let pending = take_buffered(&mut self.buffers.lock().unwrap(), &term_id);
        if let Some(ch) = outputs.get(&term_id) {
            for chunk in pending {
                let _ = ch.send(InvokeResponseBody::Raw(chunk));
            }
        }
    }

    pub fn detach_output(&self, term_id: &str) {
        self.outputs.lock().unwrap().remove(term_id);
        // NOTE: buffer is intentionally NOT cleared here. A transient
        // detach+reattach should still deliver the pending bytes on the next
        // attach_output call. The bounded cap prevents unbounded growth.
    }

    /// Forget a terminal entirely: drop its output channel AND its scrollback
    /// buffer. Called on `term_detach` (a card unmounted for good — exit-removal
    /// or board prune), so neither the channel nor a never-to-be-drained buffer
    /// lingers. Lock order outputs → buffers (consistent with dispatch/attach).
    pub fn forget_term(&self, term_id: &str) {
        self.outputs.lock().unwrap().remove(term_id);
        self.buffers.lock().unwrap().remove(term_id);
    }
}

// ── Version check ────────────────────────────────────────────────────────────

/// True iff the daemon's reported version differs from the expected version (or
/// is absent) AND we have not already triggered a restart for this mismatch.
/// The `already_restarted` latch prevents a second restart when the newly-spawned
/// daemon still reports a wrong version (bad PATH, stale install, etc.); in that
/// case the persistent mismatch surfaces via the daemon-status event instead.
fn should_restart(expected: &str, reported: Option<&str>, already_restarted: bool) -> bool {
    reported != Some(expected) && !already_restarted
}

// ── Pure buffer helpers (unit-testable without Tauri types) ──────────────────

/// Push `bytes` into the per-term output buffer, evicting oldest chunks when the
/// total byte count for that term would exceed `cap`. An empty `bytes` slice is a
/// no-op. The eviction strategy is FIFO (oldest-first), matching scrollback
/// semantics: we keep the most-recent output.
fn push_buffered(
    map: &mut HashMap<String, VecDeque<Vec<u8>>>,
    term_id: &str,
    bytes: Vec<u8>,
    cap: usize,
) {
    if bytes.is_empty() {
        return;
    }
    let deque = map.entry(term_id.to_string()).or_default();

    // If this single chunk is larger than the cap, just keep the tail of it.
    let bytes = if bytes.len() > cap {
        bytes[bytes.len() - cap..].to_vec()
    } else {
        bytes
    };

    // Evict oldest chunks until there is room for the new one.
    let mut total: usize = deque.iter().map(|c| c.len()).sum();
    while total + bytes.len() > cap {
        if let Some(evicted) = deque.pop_front() {
            total -= evicted.len();
        } else {
            break;
        }
    }
    deque.push_back(bytes);
}

/// Remove and return all buffered chunks for `term_id` in order (oldest first).
/// Returns an empty Vec if there is no buffer entry for that term.
fn take_buffered(
    map: &mut HashMap<String, VecDeque<Vec<u8>>>,
    term_id: &str,
) -> Vec<Vec<u8>> {
    map.remove(term_id)
        .map(|d| d.into_iter().collect())
        .unwrap_or_default()
}

/// Spawn the long-lived connection task onto Tauri's async (tokio) runtime.
pub fn start(app: AppHandle, rx: UnboundedReceiver<Msg>) {
    tauri::async_runtime::spawn(connection_loop(app, rx));
}

/// The reconnect-bounded outer loop: connect (spawning the daemon on a miss
/// whenever we are not already supervising a live one), run the connection until
/// it drops, then back off on the `Reconnect` schedule until the budget is spent.
async fn connection_loop(app: AppHandle, mut rx: UnboundedReceiver<Msg>) {
    let mut spawned = false;
    let mut already_restarted = false;
    let mut attempt: u32 = 0;
    loop {
        match connect(&app, &mut spawned).await {
            Ok(stream) => {
                attempt = 0;
                emit_status(&app, true, None);
                if run_connection(&app, &mut rx, stream, already_restarted).await {
                    spawned = false;
                    already_restarted = true;
                    continue;
                }
                emit_status(&app, false, Some("daemon connection closed"));
            }
            Err(e) => emit_status(&app, false, Some(&format!("connect failed: {e}"))),
        }
        attempt += 1;
        match reconnect_delay(attempt) {
            Some(d) => tokio::time::sleep(d).await,
            None => {
                emit_status(&app, false, Some("could not reconnect to tarmacd"));
                break;
            }
        }
    }
}

/// One connection: handshake (`hello`), version-check the `HelloOk`, then
/// `select!` between reading daemon frames (→ dispatch) and draining the outbound
/// queue (→ frame onto socket). Returns `true` if a version-mismatch restart was
/// triggered (caller must reset `spawned` and reconnect); `false` on normal exit.
async fn run_connection(
    app: &AppHandle,
    rx: &mut UnboundedReceiver<Msg>,
    stream: UnixStream,
    already_restarted: bool,
) -> bool {
    let (mut read_half, mut write_half) = stream.into_split();

    let hello = encode(&Msg::Hello { role: "app".into(), v: PROTOCOL_VERSION }).expect("hello encodes");
    if frame::write_async(&mut write_half, &hello).await.is_err() {
        return false;
    }

    // First inbound frame is always HelloOk; check daemon version before the loop.
    let first_payload = match frame::read_async(&mut read_half).await {
        Ok(p) => p,
        Err(_) => return false,
    };
    let first_msg = match decode(&first_payload) {
        Ok(m) => m,
        Err(_) => return false,
    };
    let (reported_version, reported_pid) = match &first_msg {
        Msg::HelloOk { daemon_version, daemon_pid, .. } => (daemon_version.clone(), *daemon_pid),
        _ => (None, None),
    };

    if should_restart(env!("CARGO_PKG_VERSION"), reported_version.as_deref(), already_restarted) {
        emit_status(app, false, Some("version mismatch / restarting"));
        // SIGTERM the daemon the handshake came from, by its reported pid — this
        // is the brew-upgrade case where the app did NOT spawn the stale daemon
        // (so daemon_child is None). The tracked child is a secondary fallback.
        let pid = reported_pid.or_else(|| {
            let bridge = app.state::<Bridge>();
            let guard = bridge.daemon_child.lock().unwrap();
            guard.as_ref().map(|c| c.id())
        });
        if let Some(pid) = pid {
            unsafe { libc::kill(pid as i32, libc::SIGTERM); }
        }
        // Wait for the dying daemon to remove its socket before spawning the new
        // binary, so the new daemon's claim_socket() does not see a live daemon
        // and exit(1). Bounded so a wedged daemon still lets us proceed.
        let sock = socket_path();
        let deadline = Instant::now() + Duration::from_secs(2);
        while sock.exists() && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        return true;
    }

    dispatch(app, first_msg);

    loop {
        tokio::select! {
            inbound = frame::read_async(&mut read_half) => {
                match inbound {
                    Ok(payload) => match decode(&payload) {
                        Ok(msg) => dispatch(app, msg),
                        // Malformed frame is non-fatal (matches the Swift read loop).
                        Err(_) => {}
                    },
                    Err(_) => break, // EOF or socket error → drop, let the outer loop reconnect
                }
            }
            outbound = rx.recv() => {
                match outbound {
                    Some(msg) => {
                        let Ok(bytes) = encode(&msg) else { continue };
                        if frame::write_async(&mut write_half, &bytes).await.is_err() {
                            break;
                        }
                    }
                    None => break, // sender dropped (shutdown)
                }
            }
        }
    }
    false
}

/// Route one daemon message to the frontend. `Output` streams over the owning
/// terminal's binary Channel (raw bytes → ArrayBuffer, no JSON); every other
/// message is emitted as a JSON `"daemon"` event keyed by its `"t"` tag.
fn dispatch(app: &AppHandle, msg: Msg) {
    let bridge = app.state::<Bridge>();
    match msg {
        Msg::Output { term_id, bytes } => {
            // Hold `outputs` across the whole arm so the channel-present decision
            // and the buffer push are atomic against `attach_output` (same lock
            // order, outputs → buffers). Without this, an attach racing in could
            // drain the buffer and then this byte would be buffered forever.
            let outputs = bridge.outputs.lock().unwrap();
            if let Some(channel) = outputs.get(&term_id) {
                // Fast path: channel is attached — send directly.
                let _ = channel.send(InvokeResponseBody::Raw(bytes));
            } else {
                // No channel yet (daemon replayed scrollback before `term_attach`).
                // Buffer the bytes; drained in order when attach_output is called.
                push_buffered(
                    &mut bridge.buffers.lock().unwrap(),
                    &term_id,
                    bytes,
                    BUFFER_CAP_BYTES,
                );
            }
        }
        other => {
            if let Ok(value) = serde_json::to_value(&other) {
                let tag = value.get("t").and_then(|t| t.as_str()).unwrap_or("?");
                bridge.remember_msg(tag, &value);
                let _ = app.emit("daemon", value);
            }
        }
    }
}

fn emit_status(app: &AppHandle, connected: bool, reason: Option<&str>) {
    let value = serde_json::json!({ "connected": connected, "reason": reason });
    app.state::<Bridge>().remember_status(value.clone());
    let _ = app.emit("daemon-status", value);
}

/// Connect to the daemon socket, spawning `tarmacd` on a miss and retrying for
/// ~3s (mirrors `DaemonClient.connect`). The spawn is gated on `may_spawn_now`
/// rather than a bare latch: we skip it only while a daemon we started is still
/// alive, so a spawn that failed or died never locks the app out.
async fn connect(app: &AppHandle, spawned: &mut bool) -> std::io::Result<UnixStream> {
    let path = socket_path();
    if let Err(msg) = check_socket_path_len(&path) {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, msg));
    }
    if let Ok(stream) = UnixStream::connect(&path).await {
        return Ok(stream);
    }
    if may_spawn_now(*spawned, &app.state::<Bridge>().daemon_child) {
        if let Some(daemon) = resolve_daemon_path() {
            *spawned = spawn_daemon(app, &daemon);
        }
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if let Ok(stream) = UnixStream::connect(&path).await {
            return Ok(stream);
        }
        if Instant::now() >= deadline {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("no daemon at {}", path.display()),
            ));
        }
    }
}

/// The daemon socket path, reusing core's per-channel resolver. Debug builds use
/// the `dev/` channel (matching `tarmacd`'s own `cfg!(debug_assertions)`), and a
/// non-empty `TARMAC_SOCKET` overrides verbatim — so `make run` pins a
/// per-worktree path exactly like `make run` does for the Swift app.
fn socket_path() -> PathBuf {
    let over: Option<OsString> = std::env::var_os("TARMAC_SOCKET");
    let home = std::env::var_os("HOME").unwrap_or_default();
    let channel = if cfg!(debug_assertions) {
        WireChannel::Dev
    } else {
        WireChannel::Release
    };
    resolve_socket_path(over, home.as_os_str(), channel)
}

/// Pure, testable resolver — mirror of Swift `DaemonLaunch.resolveDaemonPath`:
/// a non-empty `env_override` wins verbatim; else the `tarmacd` sibling of
/// `exe_dir` is returned iff `exists` reports it present; else `None`.
fn resolve_daemon_path_pure(
    env_override: Option<&str>,
    exe_dir: &Path,
    exists: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    if let Some(v) = env_override {
        if !v.is_empty() {
            return Some(PathBuf::from(v));
        }
    }
    let candidate = exe_dir.join("tarmacd");
    if exists(&candidate) {
        Some(candidate)
    } else {
        None
    }
}

/// Which daemon binary to spawn (port of `DaemonLaunch.resolveDaemonPath`): a
/// non-empty `TARMAC_DAEMON` wins verbatim (preserves `make run`).
/// In a packaged `.app`, `current_exe()` resolves to `Contents/MacOS/tarmac-app`
/// (the GUI exe — distinct from the `tarmac` CLI sidecar, which would otherwise
/// collide case-insensitively), so its parent is `Contents/MacOS` — the dir the
/// bundle also places `tarmacd` and `tarmac` into.
fn resolve_daemon_path() -> Option<String> {
    let exe_dir = std::env::current_exe().ok()?;
    let exe_dir = exe_dir.parent()?;
    let path = resolve_daemon_path_pure(
        std::env::var("TARMAC_DAEMON").ok().as_deref(),
        exe_dir,
        |p| p.exists(),
    )?;
    path.into_os_string().into_string().ok()
}

/// Launch the daemon, retaining the `Child` on `Bridge` (the version-mismatch
/// restart SIGTERMs it, and the spawn decision reads its liveness). Reports
/// whether a child was actually created — a failed spawn must not latch.
fn spawn_daemon(app: &AppHandle, daemon: &str) -> bool {
    let cli_dir = Path::new(daemon)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let base = std::env::var("PATH").ok();
    match daemon_command(daemon, base.as_deref(), &cli_dir, &daemon_log_path()).spawn() {
        Ok(child) => {
            *app.state::<Bridge>().daemon_child.lock().unwrap() = Some(child);
            true
        }
        Err(_) => false,
    }
}

/// `tarmacd.log`, beside the socket — `.dev/` under `make run`, the per-channel
/// support dir otherwise.
fn daemon_log_path() -> PathBuf {
    let sock = socket_path();
    sock.parent().unwrap_or(Path::new(".")).join("tarmacd.log")
}

/// The daemon's launch command, built but not spawned. It is genuinely detached:
/// `setsid()` puts it in its own *session*, so a SIGHUP aimed at the launching
/// terminal's session (which a new process group alone would not escape) never
/// reaches the observatory. Its output goes to `log`, truncated per launch so the
/// file is bounded by one session; if that cannot be opened the daemon still
/// starts with inherited stdio, since a bad log dir must never cost us the daemon.
/// `cli_dir` is prepended onto the child `PATH` so the PTYs it spawns resolve the
/// `tarmac` CLI (port of `DaemonLaunch`).
fn daemon_command(program: &str, base_path: Option<&str>, cli_dir: &str, log: &Path) -> Command {
    let mut cmd = Command::new(program);
    cmd.stdin(Stdio::null())
        .env("PATH", inject_cli_path(base_path, cli_dir));
    if let Some(out) = open_log(log) {
        if let Ok(err) = out.try_clone() {
            cmd.stdout(Stdio::from(out)).stderr(Stdio::from(err));
        }
    }
    // Runs between fork and exec: only async-signal-safe calls belong here.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    cmd
}

fn open_log(path: &Path) -> Option<std::fs::File> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok()?;
    }
    std::fs::OpenOptions::new().write(true).create(true).truncate(true).open(path).ok()
}

/// May we spawn a daemon on this pass? The latch is there to stop us piling a
/// second daemon onto one we just started — which is only a reason to wait while
/// that child is actually alive.
fn may_spawn(already_spawned: bool, prior_child_exited: bool) -> bool {
    !already_spawned || prior_child_exited
}

/// "No live child we spawned": `Command::spawn` never produced one (`None`), the
/// one it produced has exited, or we cannot tell. Only an observed-live child
/// blocks a respawn — a `try_wait` error is the "we don't know" case, and
/// answering it with `false` would be the very defect this function exists to
/// remove: an unknown state that locks the app out permanently. Erring the other
/// way costs at most one extra spawn per pass, bounded by the reconnect budget.
fn prior_child_exited(child: Option<&mut std::process::Child>) -> bool {
    match child {
        None => true,
        Some(child) => !matches!(child.try_wait(), Ok(None)),
    }
}

/// The spawn decision over the live child slot. Takes the lock for the
/// `try_wait` observation and releases it before returning — `connect()` is
/// `async` and this is a `std::sync::Mutex`.
fn may_spawn_now(already_spawned: bool, slot: &Mutex<Option<std::process::Child>>) -> bool {
    let mut guard = slot.lock().unwrap();
    may_spawn(already_spawned, prior_child_exited(guard.as_mut()))
}

/// Pure backoff schedule — exact port of `Reconnect.delay(forAttempt:)`: ramp
/// 0.5→1→2→4→8 s, then hold at a 15 s cap, for a bounded 10 attempts; `None`
/// (stop retrying) for attempt 0 or past the budget.
fn reconnect_delay(attempt: u32) -> Option<Duration> {
    const RAMP: [f64; 5] = [0.5, 1.0, 2.0, 4.0, 8.0];
    const CAP: f64 = 15.0;
    const MAX_ATTEMPTS: u32 = 10;
    if attempt < 1 || attempt > MAX_ATTEMPTS {
        return None;
    }
    let secs = if (attempt as usize) <= RAMP.len() {
        RAMP[attempt as usize - 1]
    } else {
        CAP
    };
    Some(Duration::from_secs_f64(secs))
}

/// Pure `PATH` injection — exact port of `DaemonLaunch.injectCLIPath`: prepend
/// `cli_dir` as the first colon segment unless it is already an exact segment
/// (idempotent; a substring is not a segment). Empty `cli_dir` is never
/// prepended (would add a stray leading colon).
fn inject_cli_path(base: Option<&str>, cli_dir: &str) -> String {
    if cli_dir.is_empty() {
        return base.unwrap_or("").to_string();
    }
    let base = match base {
        Some(b) if !b.is_empty() => b,
        _ => return cli_dir.to_string(),
    };
    if base.split(':').any(|seg| seg == cli_dir) {
        return base.to_string();
    }
    format!("{cli_dir}:{base}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tarmac-bridge-{}-{}",
            std::process::id(),
            DIR_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    // ── daemon_command: detachment, logging, PATH ─────────────────────────────

    /// The spawned daemon is its own session leader, so a session-wide SIGHUP
    /// aimed at the launching terminal cannot reach it.
    #[test]
    fn daemon_command_starts_its_own_session() {
        let dir = temp_dir();
        let mut child = daemon_command("/bin/sleep", None, "", &dir.join("tarmacd.log"))
            .arg("30")
            .spawn()
            .unwrap();

        let pid = child.id() as libc::pid_t;
        let sid = unsafe { libc::getsid(pid) };
        assert_eq!(sid, pid, "daemon must be a session leader, got sid {sid} for pid {pid}");
        assert_ne!(sid, unsafe { libc::getsid(0) }, "daemon must leave our session");

        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Both streams land in the log, and its directory is created on the way.
    #[test]
    fn daemon_command_logs_both_streams_into_a_created_dir() {
        let dir = temp_dir();
        let log = dir.join("not-yet").join("tarmacd.log");
        let mut child = daemon_command("/bin/sh", None, "", &log)
            .args(["-c", "echo out; echo err >&2"])
            .spawn()
            .unwrap();
        child.wait().unwrap();

        let body = std::fs::read_to_string(&log).unwrap();
        assert!(body.contains("out"), "stdout must be redirected, log was {body:?}");
        assert!(body.contains("err"), "stderr must be redirected, log was {body:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Each launch truncates: the file is bounded by one daemon session.
    #[test]
    fn daemon_command_truncates_the_log_per_launch() {
        let dir = temp_dir();
        let log = dir.join("tarmacd.log");
        for marker in ["FIRST-MARKER-WITH-PADDING", "SECOND"] {
            let mut child = daemon_command("/bin/sh", None, "", &log)
                .args(["-c", &format!("echo {marker}")])
                .spawn()
                .unwrap();
            child.wait().unwrap();
        }

        assert_eq!(std::fs::read_to_string(&log).unwrap(), "SECOND\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// An unopenable log path costs the log, never the daemon.
    #[test]
    fn daemon_command_still_runs_when_the_log_cannot_be_opened() {
        let dir = temp_dir();
        let mut child = daemon_command("/bin/sh", None, "", &dir)
            .args(["-c", "exit 7"])
            .spawn()
            .unwrap();

        assert_eq!(child.wait().unwrap().code(), Some(7));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The child's PATH is the injected one, observed from the child itself.
    #[test]
    fn daemon_command_injects_cli_dir_into_the_child_path() {
        let dir = temp_dir();
        let log = dir.join("tarmacd.log");
        let mut child = daemon_command("/bin/sh", Some("/usr/bin:/bin"), "/x/bin", &log)
            .args(["-c", "printenv PATH"])
            .spawn()
            .unwrap();
        child.wait().unwrap();

        assert_eq!(std::fs::read_to_string(&log).unwrap(), "/x/bin:/usr/bin:/bin\n");
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ── the spawn decision ────────────────────────────────────────────────────

    #[test]
    fn may_spawn_allows_the_first_daemon() {
        assert!(may_spawn(false, false));
    }

    #[test]
    fn may_spawn_refuses_to_pile_onto_a_live_daemon() {
        assert!(!may_spawn(true, false));
    }

    #[test]
    fn may_spawn_allows_a_respawn_once_the_child_is_gone() {
        assert!(may_spawn(true, true));
    }

    /// The fourth row is the one that matters: no child at all means the spawn
    /// itself failed, which is nothing to pile onto.
    #[test]
    fn prior_child_exited_truth_table() {
        assert!(prior_child_exited(None), "a spawn that produced no child must permit a retry");

        let mut live = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        assert!(!prior_child_exited(Some(&mut live)));
        live.kill().unwrap();
        live.wait().unwrap();

        let mut done = Command::new("/usr/bin/true").spawn().unwrap();
        done.wait().unwrap();
        assert!(prior_child_exited(Some(&mut done)));
    }

    /// The wired decision, driven with a real child: a dead daemon re-enables
    /// spawning where a live one blocks it.
    #[test]
    fn a_dead_child_re_enables_spawning() {
        let slot = Mutex::new(Some(Command::new("/bin/sleep").arg("30").spawn().unwrap()));
        assert!(!may_spawn_now(true, &slot), "a live child must block a second spawn");

        {
            let mut guard = slot.lock().unwrap();
            let child = guard.as_mut().unwrap();
            child.kill().unwrap();
            child.wait().unwrap();
        }

        assert!(may_spawn_now(true, &slot), "a dead child must re-enable spawning");
    }

    // Mirrors ReconnectTests: ramp 0.5→1→2→4→8 then 15 s cap, bounded at 10.
    #[test]
    fn reconnect_ramp_then_cap() {
        assert_eq!(reconnect_delay(1), Some(Duration::from_secs_f64(0.5)));
        assert_eq!(reconnect_delay(2), Some(Duration::from_secs_f64(1.0)));
        assert_eq!(reconnect_delay(3), Some(Duration::from_secs_f64(2.0)));
        assert_eq!(reconnect_delay(4), Some(Duration::from_secs_f64(4.0)));
        assert_eq!(reconnect_delay(5), Some(Duration::from_secs_f64(8.0)));
        assert_eq!(reconnect_delay(6), Some(Duration::from_secs_f64(15.0)));
        assert_eq!(reconnect_delay(10), Some(Duration::from_secs_f64(15.0)));
    }

    #[test]
    fn reconnect_gives_up_past_budget() {
        assert_eq!(reconnect_delay(11), None);
        assert_eq!(reconnect_delay(0), None);
    }

    #[test]
    fn reconnect_is_monotonic_and_capped() {
        let mut last = 0.0;
        for n in 1..=10u32 {
            let d = reconnect_delay(n).unwrap().as_secs_f64();
            assert!(d >= last, "delay must not decrease at attempt {n}");
            assert!(d <= 15.0, "delay must never exceed the 15 s cap at attempt {n}");
            last = d;
        }
    }

    // Mirrors the DaemonLaunch.injectCLIPath cases.
    #[test]
    fn inject_cli_path_prepends_once() {
        assert_eq!(inject_cli_path(Some("/usr/bin:/bin"), "/x/bin"), "/x/bin:/usr/bin:/bin");
    }

    #[test]
    fn inject_cli_path_is_idempotent_on_exact_segment() {
        assert_eq!(inject_cli_path(Some("/x/bin:/usr/bin"), "/x/bin"), "/x/bin:/usr/bin");
    }

    #[test]
    fn inject_cli_path_substring_is_not_a_segment() {
        // /x/binfoo must NOT count as already containing /x/bin.
        assert_eq!(
            inject_cli_path(Some("/x/binfoo:/usr/bin"), "/x/bin"),
            "/x/bin:/x/binfoo:/usr/bin"
        );
    }

    #[test]
    fn inject_cli_path_empty_inputs() {
        assert_eq!(inject_cli_path(None, "/x/bin"), "/x/bin");
        assert_eq!(inject_cli_path(Some(""), "/x/bin"), "/x/bin");
        assert_eq!(inject_cli_path(Some("/usr/bin"), ""), "/usr/bin");
        assert_eq!(inject_cli_path(None, ""), "");
    }

    // ── Scrollback buffer helper tests ────────────────────────────────────────

    /// Bytes buffered before attach are returned in order (oldest first) by
    /// take_buffered, and the entry is removed from the map.
    #[test]
    fn buffer_push_then_take_delivers_in_order() {
        let mut map = HashMap::new();
        push_buffered(&mut map, "t1", b"hello ".to_vec(), BUFFER_CAP_BYTES);
        push_buffered(&mut map, "t1", b"world".to_vec(), BUFFER_CAP_BYTES);

        let chunks = take_buffered(&mut map, "t1");
        assert_eq!(chunks, vec![b"hello ".to_vec(), b"world".to_vec()]);

        // Entry must be removed after take.
        assert!(!map.contains_key("t1"));
    }

    /// take_buffered on an unknown term returns an empty Vec (no panic).
    #[test]
    fn buffer_take_unknown_term_returns_empty() {
        let mut map: HashMap<String, VecDeque<Vec<u8>>> = HashMap::new();
        let chunks = take_buffered(&mut map, "unknown");
        assert!(chunks.is_empty());
    }

    /// Buffers for different term_ids are independent.
    #[test]
    fn buffer_independent_per_term() {
        let mut map = HashMap::new();
        push_buffered(&mut map, "t1", b"for t1".to_vec(), BUFFER_CAP_BYTES);
        push_buffered(&mut map, "t2", b"for t2".to_vec(), BUFFER_CAP_BYTES);

        let t1 = take_buffered(&mut map, "t1");
        assert_eq!(t1, vec![b"for t1".to_vec()]);

        let t2 = take_buffered(&mut map, "t2");
        assert_eq!(t2, vec![b"for t2".to_vec()]);
    }

    /// When the cap is exceeded, oldest chunks are evicted to stay within the cap.
    #[test]
    fn buffer_cap_evicts_oldest() {
        let cap = 10;
        let mut map = HashMap::new();

        // Push three 5-byte chunks; only the last two fit under cap=10.
        push_buffered(&mut map, "t1", b"AAAAA".to_vec(), cap); // total 5, fits
        push_buffered(&mut map, "t1", b"BBBBB".to_vec(), cap); // total 10, fits
        push_buffered(&mut map, "t1", b"CCCCC".to_vec(), cap); // would be 15, so AAAAA evicted

        let chunks = take_buffered(&mut map, "t1");
        let combined: Vec<u8> = chunks.into_iter().flatten().collect();
        // Only B and C survive; A was evicted.
        assert_eq!(combined, b"BBBBBCCCCC".to_vec());
    }

    /// A single chunk larger than the cap is itself tail-trimmed to the cap.
    #[test]
    fn buffer_oversized_single_chunk_is_trimmed() {
        let cap = 4;
        let mut map = HashMap::new();
        push_buffered(&mut map, "t1", b"ABCDEFGH".to_vec(), cap);

        let chunks = take_buffered(&mut map, "t1");
        let combined: Vec<u8> = chunks.into_iter().flatten().collect();
        // Only the last `cap` bytes survive.
        assert_eq!(combined, b"EFGH".to_vec());
    }

    /// Empty bytes slice is a no-op (does not create a map entry).
    #[test]
    fn buffer_empty_bytes_is_noop() {
        let mut map = HashMap::new();
        push_buffered(&mut map, "t1", vec![], BUFFER_CAP_BYTES);
        assert!(!map.contains_key("t1"));
    }

    /// After take_buffered, a second take for the same term is empty (idempotent drain).
    #[test]
    fn buffer_double_take_is_empty() {
        let mut map = HashMap::new();
        push_buffered(&mut map, "t1", b"data".to_vec(), BUFFER_CAP_BYTES);

        let _ = take_buffered(&mut map, "t1");
        let second = take_buffered(&mut map, "t1");
        assert!(second.is_empty());
    }

    // ── resolve_daemon_path_pure tests ────────────────────────────────────────

    /// Non-empty env override wins even when sibling exists.
    #[test]
    fn resolve_daemon_env_wins() {
        let dir = Path::new("/some/dir");
        let result = resolve_daemon_path_pure(Some("/custom/tarmacd"), dir, |_| true);
        assert_eq!(result, Some(PathBuf::from("/custom/tarmacd")));
    }

    /// No env, sibling exists → returns the sibling path.
    #[test]
    fn resolve_daemon_sibling_exists() {
        let dir = Path::new("/app/Contents/MacOS");
        let result = resolve_daemon_path_pure(None, dir, |p| p == Path::new("/app/Contents/MacOS/tarmacd"));
        assert_eq!(result, Some(PathBuf::from("/app/Contents/MacOS/tarmacd")));
    }

    /// No env, sibling missing → None.
    #[test]
    fn resolve_daemon_sibling_missing_returns_none() {
        let dir = Path::new("/app/Contents/MacOS");
        let result = resolve_daemon_path_pure(None, dir, |_| false);
        assert_eq!(result, None);
    }

    /// Empty env string falls through to the sibling branch.
    #[test]
    fn resolve_daemon_empty_env_falls_through_to_sibling() {
        let dir = Path::new("/app/Contents/MacOS");
        // Empty string must not count as an override.
        let result = resolve_daemon_path_pure(Some(""), dir, |p| p == Path::new("/app/Contents/MacOS/tarmacd"));
        assert_eq!(result, Some(PathBuf::from("/app/Contents/MacOS/tarmacd")));
    }

    // ── should_restart tests ─────────────────────────────────────────────────

    #[test]
    fn should_restart_equal_versions_is_false() {
        assert!(!should_restart("0.1.0", Some("0.1.0"), false));
    }

    #[test]
    fn should_restart_differing_versions_is_true() {
        assert!(should_restart("0.2.0", Some("0.1.0"), false));
    }

    #[test]
    fn should_restart_none_version_is_true() {
        assert!(should_restart("0.1.0", None, false));
    }

    #[test]
    fn should_restart_already_restarted_is_false() {
        assert!(!should_restart("0.2.0", Some("0.1.0"), true));
        assert!(!should_restart("0.1.0", None, true));
    }

}
