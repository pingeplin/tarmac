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
        let mut conn = Conn::connect(sock);
        conn.send(&Msg::Hello { role: role.into(), v: proto::PROTOCOL_VERSION });
        let reply = conn.recv(Instant::now() + LONG, "hello_ok");
        assert!(matches!(reply, Msg::HelloOk { v: 1 }), "expected hello_ok, got {reply:?}");
        conn
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
