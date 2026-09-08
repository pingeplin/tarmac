// Shared integration harness: a real daemon process on a temp socket + state
// file, with app/cli clients speaking the wire protocol over std sockets.
#![allow(dead_code)] // each test binary uses a different slice of the harness

use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::{self as proto, Msg, frame};

pub const LONG: Duration = Duration::from_secs(20);

// Counter, not just a timestamp: parallel test threads can hit the same
// nanosecond and would then share (and tear down) each other's socket dir.
static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

pub fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-it-{}-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

pub struct TestDaemon {
    pub child: Child,
    pub dir: PathBuf,
    pub sock: PathBuf,
}

impl TestDaemon {
    pub fn start() -> Self {
        let dir = temp_dir();
        let sock = dir.join("tarmacd.sock");
        let child = spawn_daemon(&sock);
        wait_for_socket(&sock);
        TestDaemon { child, dir, sock }
    }

    pub fn state_file(&self) -> PathBuf {
        self.dir.join("state.json")
    }

    // SIGKILL + relaunch against the same socket/state paths.
    pub fn restart(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.child = spawn_daemon(&self.sock);
        wait_for_socket(&self.sock);
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub fn spawn_daemon(sock: &Path) -> Child {
    let state = sock.parent().expect("socket has a parent dir").join("state.json");
    Command::new(env!("CARGO_BIN_EXE_tarmacd"))
        .env("TARMAC_SOCKET", sock)
        .env("TARMAC_STATE", state)
        .env("RUST_LOG", "debug")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn tarmacd")
}

pub fn wait_for_socket(sock: &Path) {
    let deadline = Instant::now() + LONG;
    while Instant::now() < deadline {
        if UnixStream::connect(sock).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("daemon socket never became connectable: {}", sock.display());
}

pub struct Conn(pub UnixStream);

impl Conn {
    pub fn connect(sock: &Path) -> Self {
        let stream = UnixStream::connect(sock).expect("connect");
        stream.set_write_timeout(Some(LONG)).unwrap();
        Conn(stream)
    }

    pub fn hello(sock: &Path, role: &str) -> Self {
        Conn::hello_as(sock, role, None).0
    }

    /// `hello` with an explicit `app_version`, returning the `hello_ok` too so a
    /// test can read what the daemon reported back (spec 2609.0012).
    pub fn hello_as(sock: &Path, role: &str, app_version: Option<&str>) -> (Self, Msg) {
        let mut conn = Conn::connect(sock);
        conn.send(&Msg::Hello {
            role: role.into(),
            v: proto::PROTOCOL_VERSION,
            app_version: app_version.map(str::to_string),
        });
        let reply = conn.recv(Instant::now() + LONG, "hello_ok");
        assert!(matches!(reply, Msg::HelloOk { v: 1, .. }), "expected hello_ok, got {reply:?}");
        (conn, reply)
    }

    /// The app-slot fields of a fresh `cli` handshake: `(app_connected, app_version)`.
    pub fn probe_app_slot(sock: &Path) -> (Option<bool>, Option<String>) {
        let (_, reply) = Conn::hello_as(sock, "cli", None);
        let Msg::HelloOk { app_connected, app_version, .. } = reply else {
            panic!("expected hello_ok, got {reply:?}")
        };
        (app_connected, app_version)
    }

    pub fn send(&mut self, msg: &Msg) {
        let payload = proto::encode(msg).unwrap();
        frame::write_sync(&mut self.0, &payload).expect("write frame");
    }

    pub fn recv(&mut self, deadline: Instant, what: &str) -> Msg {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for {what}");
        self.0.set_read_timeout(Some(remaining)).unwrap();
        let payload = frame::read_sync(&mut self.0)
            .unwrap_or_else(|e| panic!("read frame while waiting for {what}: {e}"));
        proto::decode(&payload).expect("decode frame")
    }

    pub fn recv_until(&mut self, what: &str, mut pred: impl FnMut(&Msg) -> bool) -> Msg {
        let deadline = Instant::now() + LONG;
        loop {
            let msg = self.recv(deadline, what);
            if pred(&msg) {
                return msg;
            }
        }
    }
}

pub fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

// Drain all messages arriving within `timeout`, returning true if none of them
// match `pred`. Used to assert the absence of a message (e.g. no FileEvent for a
// closed doc's path after it has been unwatched). Sets the stream's read timeout
// around the window and restores the LONG timeout afterwards.
pub fn none_within(conn: &mut Conn, timeout: Duration, mut pred: impl FnMut(&Msg) -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        conn.0.set_read_timeout(Some(remaining)).unwrap();
        match frame::read_sync(&mut conn.0) {
            Ok(payload) => {
                if let Ok(msg) = proto::decode(&payload) {
                    if pred(&msg) {
                        conn.0.set_read_timeout(Some(LONG)).unwrap();
                        return false;
                    }
                }
            }
            Err(_) => break,
        }
    }
    conn.0.set_read_timeout(Some(LONG)).unwrap();
    true
}

pub fn write_doc(path: &Path, content: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

pub fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
}

/// Drain the connect-time board_list + restore so later reads see only the
/// frames the test drives.
pub fn drain_connect(app: &mut Conn) {
    app.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
}

pub fn wait_for_state(state: &Path, what: &str, pred: impl Fn(&serde_json::Value) -> bool) {
    let deadline = Instant::now() + LONG;
    loop {
        if let Ok(bytes) = std::fs::read(state)
            && let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes)
            && pred(&v)
        {
            return;
        }
        assert!(Instant::now() < deadline, "state file never showed {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Send `sig` to a daemon child and wait, to a deadline, for it to exit.
/// Returns the exit status so a test can distinguish a clean `exit(0)` from a
/// death by signal (`status.code() == None`).
pub fn signal_and_wait(child: &mut Child, sig: libc::c_int) -> std::process::ExitStatus {
    unsafe { libc::kill(child.id() as libc::pid_t, sig) };
    let deadline = Instant::now() + LONG;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "daemon never exited after signal {sig}");
        std::thread::sleep(Duration::from_millis(25));
    }
}
