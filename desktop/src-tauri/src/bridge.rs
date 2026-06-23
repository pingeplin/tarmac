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

use std::collections::HashMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tarmac_protocol::{
    decode, encode, frame, resolve_socket_path, Channel as WireChannel, Msg, PROTOCOL_VERSION,
};
use tauri::ipc::{Channel as IpcChannel, InvokeResponseBody};
use tauri::{AppHandle, Emitter, Manager};
use tokio::net::UnixStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

/// Shared bridge state, managed by Tauri (`app.manage`). Commands look it up via
/// `State<Bridge>`; the connection task looks it up via `app.state::<Bridge>()`.
pub struct Bridge {
    /// Outbound queue to the daemon. Commands push here; the connection task
    /// drains it and frames each `Msg` onto the socket. Unbounded so a brief
    /// disconnect buffers rather than blocks the UI thread.
    tx: UnboundedSender<Msg>,
    /// Per-terminal binary output sinks the frontend registers via `term_attach`.
    outputs: Mutex<HashMap<String, IpcChannel<InvokeResponseBody>>>,
    // The Rust setup hook connects to the daemon BEFORE the webview's JS mounts,
    // so the connection's first status/board_list/restore are emitted with no
    // listener yet. We remember the latest of each (the daemon's authoritative
    // current state) and replay them when the frontend signals it is ready — which
    // also makes a dev HMR reload re-sync cleanly.
    last_status: Mutex<Option<serde_json::Value>>,
    last_board_list: Mutex<Option<serde_json::Value>>,
    last_restore: Mutex<Option<serde_json::Value>>,
}

impl Bridge {
    pub fn new(tx: UnboundedSender<Msg>) -> Self {
        Self {
            tx,
            outputs: Mutex::new(HashMap::new()),
            last_status: Mutex::new(None),
            last_board_list: Mutex::new(None),
            last_restore: Mutex::new(None),
        }
    }

    fn remember_status(&self, value: serde_json::Value) {
        *self.last_status.lock().unwrap() = Some(value);
    }

    fn remember_msg(&self, tag: &str, value: &serde_json::Value) {
        match tag {
            "board_list" => *self.last_board_list.lock().unwrap() = Some(value.clone()),
            "restore" => *self.last_restore.lock().unwrap() = Some(value.clone()),
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
        if let Some(r) = self.last_restore.lock().unwrap().clone() {
            let _ = app.emit("daemon", r);
        }
    }

    /// Enqueue a message for the daemon (fire-and-forget; the protocol has no
    /// request ids). Dropping the receiver only happens at shutdown.
    pub fn send(&self, msg: Msg) {
        let _ = self.tx.send(msg);
    }

    pub fn attach_output(&self, term_id: String, channel: IpcChannel<InvokeResponseBody>) {
        self.outputs.lock().unwrap().insert(term_id, channel);
    }

    pub fn detach_output(&self, term_id: &str) {
        self.outputs.lock().unwrap().remove(term_id);
    }
}

/// Spawn the long-lived connection task onto Tauri's async (tokio) runtime.
pub fn start(app: AppHandle, rx: UnboundedReceiver<Msg>) {
    tauri::async_runtime::spawn(connection_loop(app, rx));
}

/// The reconnect-bounded outer loop: connect (auto-spawning the daemon on the
/// first miss), run the connection until it drops, then back off on the
/// `Reconnect` schedule until the bounded budget is spent.
async fn connection_loop(app: AppHandle, mut rx: UnboundedReceiver<Msg>) {
    let mut spawned = false;
    let mut attempt: u32 = 0;
    loop {
        match connect(&mut spawned).await {
            Ok(stream) => {
                attempt = 0;
                emit_status(&app, true, None);
                run_connection(&app, &mut rx, stream).await;
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

/// One connection: handshake (`hello`), then `select!` between reading daemon
/// frames (→ dispatch) and draining the outbound queue (→ frame onto socket).
/// Returns when the socket EOFs/errors or a write fails.
async fn run_connection(app: &AppHandle, rx: &mut UnboundedReceiver<Msg>, stream: UnixStream) {
    let (mut read_half, mut write_half) = stream.into_split();

    let hello = encode(&Msg::Hello {
        role: "app".into(),
        v: PROTOCOL_VERSION,
    })
    .expect("hello encodes");
    if frame::write_async(&mut write_half, &hello).await.is_err() {
        return;
    }

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
}

/// Route one daemon message to the frontend. `Output` streams over the owning
/// terminal's binary Channel (raw bytes → ArrayBuffer, no JSON); every other
/// message is emitted as a JSON `"daemon"` event keyed by its `"t"` tag.
fn dispatch(app: &AppHandle, msg: Msg) {
    let bridge = app.state::<Bridge>();
    match msg {
        Msg::Output { term_id, bytes } => {
            let outputs = bridge.outputs.lock().unwrap();
            if let Some(channel) = outputs.get(&term_id) {
                let _ = channel.send(InvokeResponseBody::Raw(bytes));
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

/// Connect to the daemon socket, auto-spawning `tarmacd` on the first miss and
/// retrying for ~3s (mirrors `DaemonClient.connect`). `spawned` latches so we
/// only launch one daemon across reconnects.
async fn connect(spawned: &mut bool) -> std::io::Result<UnixStream> {
    let path = socket_path();
    if let Ok(stream) = UnixStream::connect(&path).await {
        return Ok(stream);
    }
    if !*spawned {
        if let Some(daemon) = resolve_daemon_path() {
            spawn_daemon(&daemon);
            *spawned = true;
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
/// non-empty `TARMAC_SOCKET` overrides verbatim — so `make run-desktop` pins a
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

/// Which daemon binary to spawn (port of `DaemonLaunch.resolveDaemonPath`): a
/// non-empty `TARMAC_DAEMON` wins verbatim (preserves `make run-desktop`).
/// Bundled-binary resolution under Tauri's `.app` layout is a Phase-6 concern.
fn resolve_daemon_path() -> Option<String> {
    match std::env::var("TARMAC_DAEMON") {
        Ok(v) if !v.is_empty() => Some(v),
        _ => None,
    }
}

/// Launch the daemon detached, prepending its own dir onto the child `PATH` so
/// the PTYs it spawns resolve the `tarmac` CLI (port of `DaemonLaunch`).
fn spawn_daemon(daemon: &str) {
    let cli_dir = Path::new(daemon)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let base = std::env::var("PATH").ok();
    let _ = Command::new(daemon)
        .stdin(Stdio::null())
        .env("PATH", inject_cli_path(base.as_deref(), &cli_dir))
        .spawn();
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
}
