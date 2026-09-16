//! The in-app QA driver's endpoint (spec 2609.0015, issue #166).
//!
//! A second Unix socket the APP owns, so an outside process can drive and read
//! the cockpit without a keyboard. Compiled out of release builds entirely — the
//! module is behind `#[cfg(debug_assertions)]` at its `mod` declaration, the same
//! predicate the audited channel mapping uses, so availability and channel cannot
//! disagree.
//!
//! The backend is a relay and nothing more: it frames requests in, hands them to
//! the frontend (which owns every decision about what a verb means), and frames
//! the frontend's answer back. Two properties make that safe to leave unattended:
//!
//!   - every wait is BOUNDED, so a scenario can never wedge on a frontend that
//!     is not there (`app_not_ready`) or does not answer (`app_unresponsive`);
//!   - replies are routed by request id, so a late answer to one request can
//!     never be handed to another.
//!
//! The frontend sink is taken by argument rather than reached for through an
//! `AppHandle`, which is what lets the tests below drive the whole relay with a
//! recording closure — the shape `bridge.rs`'s `recording_channel` established.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tarmac_protocol::dev::{DevReply, DevRequest, decode_request, encode_reply};
use tarmac_protocol::frame;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::oneshot;

/// How long the backend waits past the frontend's own budget. The three
/// deadlines nest — frontend `timeout_ms`, backend `+2000`, CLI `+3000` — so the
/// innermost one always fires and an expired wait is reported by whoever
/// actually observed it.
const BACKEND_SLACK_MS: u64 = 2_000;

/// Hands a request to the frontend. Boxed rather than an `AppHandle` so the relay
/// is drivable from a test.
pub type Sink = Box<dyn Fn(u64, &DevRequest) + Send + Sync>;

#[derive(Default)]
pub struct DevDriver {
    next_id: AtomicU64,
    pending: Mutex<HashMap<u64, oneshot::Sender<(bool, String)>>>,
    /// Set once the frontend has attached its listener. Without it the backend
    /// cannot tell "no listener yet" from "a listener that never answered": a
    /// Tauri `emit` to a window with no listener is dropped silently.
    ready: AtomicBool,
}

impl DevDriver {
    pub fn mark_ready(&self) {
        self.ready.store(true, Ordering::SeqCst);
    }

    fn is_ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    /// Mint an id and park a slot for its answer.
    pub fn register(&self) -> (u64, oneshot::Receiver<(bool, String)>) {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        (id, rx)
    }

    /// Complete THAT id's request. An unknown or already-resolved id is a no-op:
    /// a stray reply must never be handed to whichever request happens to be
    /// waiting.
    pub fn resolve(&self, id: u64, ok: bool, body: String) {
        let sender = self.pending.lock().unwrap().remove(&id);
        if let Some(tx) = sender {
            let _ = tx.send((ok, body));
        }
    }

    fn forget(&self, id: u64) {
        self.pending.lock().unwrap().remove(&id);
    }

    /// The whole relay for one request. Never waits unbounded.
    pub async fn dispatch(&self, req: DevRequest, sink: &Sink) -> DevReply {
        if !self.is_ready() {
            return err_reply(
                "app_not_ready",
                "the Tarmac window has not attached its dev driver yet",
            );
        }
        let budget = match &req {
            DevRequest::Snapshot { timeout_ms, .. } => timeout_ms.unwrap_or(0) as u64,
            _ => 0,
        };
        let (id, rx) = self.register();
        sink(id, &req);
        match tokio::time::timeout(Duration::from_millis(budget + BACKEND_SLACK_MS), rx).await {
            Ok(Ok((ok, body))) => DevReply { ok, body },
            // The frontend dropped the slot without answering.
            Ok(Err(_)) => {
                err_reply("app_unresponsive", "the dev driver dropped the request")
            }
            Err(_) => {
                self.forget(id);
                err_reply(
                    "app_unresponsive",
                    "the dev driver did not answer within its budget",
                )
            }
        }
    }
}

/// Every app-originated failure is JSON with an `error` code, so a scenario can
/// branch on the code instead of string-matching a sentence.
fn err_reply(code: &str, message: &str) -> DevReply {
    DevReply {
        ok: false,
        body: serde_json::json!({ "error": code, "message": message }).to_string(),
    }
}

/// A bound dev socket that unlinks its path when dropped, so the next run claims
/// a free path rather than having to decide whether a leftover is stale.
///
/// Deliberately std, not tokio: the claim happens in Tauri's `setup`, which runs
/// OUTSIDE the async runtime, and `tokio::net::UnixListener::from_std` panics
/// ("there is no reactor running") when called there. [`ClaimedSocket::into_async`]
/// does the conversion, from inside the spawned task where a reactor exists.
pub struct ClaimedSocket {
    /// `None` once handed to [`ClaimedSocket::into_async`], which is how Drop
    /// knows not to unlink a path the async half now owns.
    listener: Option<std::os::unix::net::UnixListener>,
    path: PathBuf,
}

/// The same socket, registered with the reactor. Owns the unlink from here on.
pub struct AsyncSocket {
    listener: UnixListener,
    path: PathBuf,
}

impl ClaimedSocket {
    /// Call from inside a Tokio context. Consumes the claim, so the path is
    /// unlinked exactly once by whichever half is still alive.
    pub fn into_async(mut self) -> std::io::Result<AsyncSocket> {
        let listener = self.listener.take().expect("a claim can only be converted once");
        let path = std::mem::take(&mut self.path);
        listener.set_nonblocking(true)?;
        Ok(AsyncSocket { listener: UnixListener::from_std(listener)?, path })
    }
}

impl AsyncSocket {
    pub async fn accept(&self) -> std::io::Result<UnixStream> {
        Ok(self.listener.accept().await?.0)
    }
}

impl Drop for ClaimedSocket {
    fn drop(&mut self) {
        if self.listener.is_some() {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

impl Drop for AsyncSocket {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Bind the dev socket, replacing a leftover only when nothing answers on it.
///
/// Deliberately NOT the daemon's rule. `tarmacd` exits 1 when another daemon
/// holds the socket; the app must not, because losing the window over a dev-only
/// endpoint is a worse outcome than not having the endpoint. A live sibling
/// worktree's socket is left exactly as it was.
pub fn claim_dev_socket(path: &Path) -> Option<ClaimedSocket> {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if path.exists() {
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            eprintln!(
                "tarmac: a dev driver is already listening on {} — not starting a second one",
                path.display()
            );
            return None;
        }
        let _ = std::fs::remove_file(path);
    }
    let listener = std::os::unix::net::UnixListener::bind(path).ok()?;
    // `bind` leaves whatever the umask allows; the daemon's claim_socket never
    // chmods, so this is new work rather than a crib.
    let _ = std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600));
    Some(ClaimedSocket { listener: Some(listener), path: path.to_path_buf() })
}

/// One request per connection: read a frame, relay it, write the answer, close.
pub async fn serve_connection(
    mut stream: UnixStream,
    driver: Arc<DevDriver>,
    sink: &Sink,
) -> std::io::Result<()> {
    // Rejects an oversized length prefix before allocating it — the main
    // socket's rule, restated because this is a second listener.
    let payload = match frame::read_async(&mut stream).await {
        Ok(payload) => payload,
        // A peer that connected and closed without sending anything is a liveness
        // probe — exactly what `claim_dev_socket` does to a sibling app. Dropping
        // it silently is the point: logging here would make every probe noisy.
        // This also swallows a TRUNCATED frame, which reports the same errno.
        // Deliberate: the peer is gone either way, so there is nobody to tell.
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(()),
        Err(e) => return Err(e),
    };
    let reply = match decode_request(&payload) {
        Ok(DevRequest::Unknown) => err_reply(
            "unsupported_verb",
            "this build of the dev driver does not know that verb",
        ),
        Ok(req) => driver.dispatch(req, sink).await,
        Err(e) => err_reply("bad_request", &format!("undecodable frame: {e}")),
    };
    let bytes = encode_reply(&reply)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    frame::write_async(&mut stream, &bytes).await
}

// ------------------------------------------------------------------- app wiring
// Everything below needs an `AppHandle` and is therefore untestable shell; the
// relay above is where the decisions live.

use tauri::{AppHandle, Emitter, Manager, State};

/// Resolve the dev socket the same way the CLI does, through the crate's own
/// `socket_path()`-style wrapper. `TARMAC_DEV_SOCKET` wins verbatim when
/// non-empty; `make run` and `make qa` pin it per worktree.
fn dev_socket_path() -> PathBuf {
    let over = std::env::var_os("TARMAC_DEV_SOCKET");
    let home = std::env::var_os("HOME").unwrap_or_default();
    let channel = if cfg!(debug_assertions) {
        tarmac_protocol::Channel::Dev
    } else {
        tarmac_protocol::Channel::Release
    };
    tarmac_protocol::dev::resolve_dev_socket_path(over, home.as_os_str(), channel)
}

/// Bind the endpoint and serve it until the app exits. A refused claim (a live
/// sibling worktree) is logged and skipped, never fatal.
pub fn start(app: AppHandle) {
    let path = dev_socket_path();
    if let Err(e) = tarmac_protocol::check_socket_path_len(&path) {
        eprintln!("tarmac: dev driver disabled: {e}");
        return;
    }
    let Some(claimed) = claim_dev_socket(&path) else { return };
    eprintln!("tarmac: dev driver listening on {}", path.display());

    let driver: Arc<DevDriver> = app.state::<Arc<DevDriver>>().inner().clone();
    tauri::async_runtime::spawn(async move {
        // Registering with the reactor must happen HERE, not in `setup`, which
        // runs outside the runtime.
        let claimed = match claimed.into_async() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("tarmac: dev driver could not start: {e}");
                return;
            }
        };
        let emit = app.clone();
        let sink: Sink = Box::new(move |id, req| {
            let _ = emit.emit("dev-request", serde_json::json!({ "id": id, "req": req }));
        });
        loop {
            match claimed.accept().await {
                Ok(stream) => {
                    // Served inline, not spawned: the driver answers one request
                    // at a time on purpose, so every reply describes the state
                    // that verb produced and not a neighbour's.
                    if let Err(e) = serve_connection(stream, driver.clone(), &sink).await {
                        eprintln!("tarmac: dev driver connection ended: {e}");
                    }
                }
                Err(e) => {
                    eprintln!("tarmac: dev driver accept failed: {e}");
                    return;
                }
            }
        }
    });
}

/// The frontend has attached its `dev-request` listener. Without this signal the
/// backend cannot tell "not ready" from "unresponsive" — a Tauri `emit` to a
/// window with no listener is dropped silently.
#[tauri::command]
pub fn dev_ready(driver: State<Arc<DevDriver>>) {
    driver.mark_ready();
}

#[tauri::command]
pub fn dev_reply(driver: State<Arc<DevDriver>>, id: u64, ok: bool, body: String) {
    driver.resolve(id, ok, body);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;
    use tarmac_protocol::dev::DevRequest;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("tarmac-devdriver-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// S66 — the socket is created, its parent with it, and it is owner-only.
    /// `tarmacd`'s `claim_socket` never chmods, so this is new work, not a crib.
    #[test]
    fn claiming_creates_a_private_socket_and_its_parent() {
        let path = scratch("mode").join("nested").join("tarmac-dev.sock");
        let claimed = claim_dev_socket(&path).expect("expected to claim a free path");
        assert!(path.exists());
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "socket mode was {mode:#o}");
        drop(claimed);
    }

    /// S67 — a leftover file nothing is listening on is stale: replace it.
    #[test]
    fn a_stale_socket_file_is_replaced() {
        let path = scratch("stale").join("tarmac-dev.sock");
        std::fs::write(&path, b"not a socket").unwrap();
        let claimed = claim_dev_socket(&path).expect("a stale file must not block the claim");
        assert!(path.exists());
        drop(claimed);
    }

    /// S67 — a LIVE sibling's socket is never unlinked and never taken over. The
    /// daemon's rule here is to exit 1; the app must not, because losing a window
    /// over a dev-only endpoint is worse than not having the endpoint.
    #[test]
    fn a_live_siblings_socket_is_left_alone() {
        let path = scratch("live").join("tarmac-dev.sock");
        let sibling = claim_dev_socket(&path).expect("first claim should succeed");
        assert!(claim_dev_socket(&path).is_none(), "took over a live sibling's socket");
        assert!(path.exists(), "unlinked a live sibling's socket");
        drop(sibling);
    }

    /// S68 — removed on clean exit, so the next run claims rather than replaces.
    #[test]
    fn the_socket_is_removed_on_drop() {
        let path = scratch("drop").join("tarmac-dev.sock");
        let claimed = claim_dev_socket(&path).unwrap();
        assert!(path.exists());
        drop(claimed);
        assert!(!path.exists(), "socket file outlived the listener");
    }

    /// S72 — replies are routed by id. Resolving the second request must leave the
    /// first still waiting; an implementation that ignored the id and completed
    /// "the pending one" would pass every single-request test and hand a scenario
    /// another verb's answer.
    #[tokio::test]
    async fn replies_are_routed_by_request_id() {
        let driver = DevDriver::default();
        let (id_a, rx_a) = driver.register();
        let (id_b, rx_b) = driver.register();
        assert_ne!(id_a, id_b);

        driver.resolve(id_b, true, "B".into());
        assert_eq!(rx_b.await.unwrap(), (true, "B".to_string()));
        // A is untouched.
        driver.resolve(id_a, false, "A".into());
        assert_eq!(rx_a.await.unwrap(), (false, "A".to_string()));
    }

    /// S72 — an unknown or already-resolved id completes nothing.
    #[tokio::test]
    async fn an_unknown_reply_id_is_a_no_op() {
        let driver = DevDriver::default();
        let (id, rx) = driver.register();
        driver.resolve(9_999, true, "stray".into());
        driver.resolve(id, true, "mine".into());
        driver.resolve(id, true, "again".into()); // already taken: no panic, no effect
        assert_eq!(rx.await.unwrap(), (true, "mine".to_string()));
    }

    /// S70 — with no frontend registered the request is ANSWERED, not hung, and
    /// the error says which of the two states it is.
    #[tokio::test]
    async fn a_request_before_the_frontend_registers_is_answered_at_once() {
        let driver = DevDriver::default();
        let sent = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = recording_sink(sent.clone());
        let reply = driver.dispatch(DevRequest::Zoom { z: 1.0 }, &sink).await;
        assert!(!reply.ok);
        assert!(reply.body.contains("app_not_ready"), "body was {}", reply.body);
        assert!(sent.lock().unwrap().is_empty(), "emitted to a frontend that was not there");
    }

    /// S70 — a registered frontend that never replies is given up on at
    /// `(timeout_ms ?? 0) + 2000`, on a PAUSED clock: `bridge.rs`'s
    /// `await_reply_deadline` tests set the precedent for not burning real seconds.
    #[tokio::test(start_paused = true)]
    async fn a_silent_frontend_is_given_up_on_at_the_bound() {
        let driver = DevDriver::default();
        driver.mark_ready();
        let sent = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = recording_sink(sent.clone());

        let started = tokio::time::Instant::now();
        let reply = driver
            .dispatch(DevRequest::Snapshot { until: None, timeout_ms: Some(10_000) }, &sink)
            .await;
        let waited = started.elapsed();

        assert!(!reply.ok);
        assert!(reply.body.contains("app_unresponsive"), "body was {}", reply.body);
        assert_eq!(waited, Duration::from_millis(12_000));
        assert_eq!(sent.lock().unwrap().len(), 1, "the request should have been emitted once");
    }

    /// S70 — every other verb carries no budget, so the bound is the bare 2 s.
    #[tokio::test(start_paused = true)]
    async fn a_verb_without_a_budget_is_bounded_at_two_seconds() {
        let driver = DevDriver::default();
        driver.mark_ready();
        let sink = recording_sink(std::sync::Arc::new(std::sync::Mutex::new(Vec::new())));
        let started = tokio::time::Instant::now();
        let _ = driver.dispatch(DevRequest::Focus { card: None }, &sink).await;
        assert_eq!(started.elapsed(), Duration::from_millis(2_000));
    }

    /// The happy path: the frontend's reply is what the CLI gets back.
    #[tokio::test]
    async fn a_frontend_reply_becomes_the_frame() {
        let driver = std::sync::Arc::new(DevDriver::default());
        driver.mark_ready();
        let answering = driver.clone();
        let sink: Sink = Box::new(move |id, _req| {
            answering.resolve(id, true, "{\"zoom\":0.5}".into());
        });
        let reply = driver.dispatch(DevRequest::Zoom { z: 0.5 }, &sink).await;
        assert!(reply.ok);
        assert_eq!(reply.body, "{\"zoom\":0.5}");
    }

    /// S69 — a peer that connects and closes without sending a frame is dropped
    /// silently. That is precisely what `claim_dev_socket`'s liveness probe does
    /// to a sibling app, so an endpoint that errored or logged on it would make
    /// every probe noisy.
    #[tokio::test]
    async fn an_empty_connection_is_dropped_silently() {
        let path = scratch("empty").join("tarmac-dev.sock");
        let claimed = std::sync::Arc::new(claim_dev_socket(&path).unwrap().into_async().unwrap());
        let driver = std::sync::Arc::new(DevDriver::default());
        let sink: Sink = Box::new(|_, _| {});

        let accepting = claimed.clone();
        let served = tokio::spawn(async move {
            let stream = accepting.accept().await.unwrap();
            serve_connection(stream, driver, &sink).await
        });

        // Exactly what claim_dev_socket does: connect, then drop.
        drop(std::os::unix::net::UnixStream::connect(&path).unwrap());

        assert!(served.await.unwrap().is_ok(), "an empty connection must not be an error");
    }

    /// S69 — an oversized frame is refused before it is allocated, and the
    /// connection closes. The main socket's rule, restated because this is a
    /// second listener.
    #[tokio::test]
    async fn an_oversized_frame_closes_the_connection() {
        use tokio::io::AsyncWriteExt;
        let path = scratch("huge").join("tarmac-dev.sock");
        let claimed = claim_dev_socket(&path).unwrap();
        let driver = std::sync::Arc::new(DevDriver::default());
        let sink: Sink = Box::new(|_, _| {});

        let claimed = std::sync::Arc::new(claimed.into_async().unwrap());
        let accepting = claimed.clone();
        let served = tokio::spawn(async move {
            let stream = accepting.accept().await.unwrap();
            serve_connection(stream, driver, &sink).await
        });

        let mut client = tokio::net::UnixStream::connect(&path).await.unwrap();
        client.write_all(&u32::MAX.to_be_bytes()).await.unwrap();
        client.flush().await.unwrap();

        assert!(served.await.unwrap().is_err(), "an oversized frame must be refused");
    }

    fn recording_sink(sent: std::sync::Arc<std::sync::Mutex<Vec<u64>>>) -> Sink {
        Box::new(move |id, _req| sent.lock().unwrap().push(id))
    }
}
