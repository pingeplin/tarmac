// Shared integration harness: a real daemon process on a temp socket + state
// file, with app/cli clients speaking the wire protocol over std sockets.
#![allow(dead_code)] // each test binary uses a different slice of the harness

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::{self as proto, BoardMeta, BoardViewport, DocEntry, Msg, Tile, frame};

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
        Self::start_with(|_| {})
    }

    /// `configure` runs after the default environment is set, so it can override it.
    pub fn start_with(configure: impl FnOnce(&mut Command)) -> Self {
        let dir = temp_dir();
        let sock = dir.join("tarmacd.sock");
        let child = spawn_daemon_with(&sock, configure);
        wait_for_socket(&sock);
        TestDaemon { child, dir, sock }
    }

    fn state_file(&self) -> PathBuf {
        self.dir.join("state.json")
    }

    pub fn state_json(&self) -> serde_json::Value {
        serde_json::from_slice(&std::fs::read(self.state_file()).unwrap()).unwrap()
    }

    pub fn wait_for_state(&self, what: &str, pred: impl Fn(&serde_json::Value) -> bool) {
        let deadline = Instant::now() + LONG;
        loop {
            if let Ok(bytes) = std::fs::read(self.state_file())
                && let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes)
                && pred(&v)
            {
                return;
            }
            assert!(Instant::now() < deadline, "state file never showed {what}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// An app connection whose connect-time board_list + restore are still unread.
    pub fn connect_app(&self) -> Conn {
        Conn::hello(&self.sock, "app")
    }

    pub fn connect_app_drained(&self) -> Conn {
        self.connect_app_drained_as(None)
    }

    /// A drained app connection announcing `app_version`.
    pub fn connect_app_drained_as(&self, app_version: Option<&str>) -> Conn {
        let (mut app, _) = Conn::hello_as(&self.sock, "app", app_version);
        app.drain_board();
        app
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
    spawn_daemon_with(sock, |_| {})
}

fn spawn_daemon_with(sock: &Path, configure: impl FnOnce(&mut Command)) -> Child {
    let state = sock.parent().expect("socket has a parent dir").join("state.json");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_tarmacd"));
    cmd.env("TARMAC_SOCKET", sock)
        .env("TARMAC_STATE", state)
        .env("RUST_LOG", "debug")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    configure(&mut cmd);
    cmd.spawn().expect("spawn tarmacd")
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

    /// Drain the board_list + restore the daemon pushes on connect and after a
    /// board create, switch or delete, so later reads see only the frames the test
    /// drives.
    pub fn drain_board(&mut self) {
        self.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
        self.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    }

    pub fn recv_board_list(&mut self) -> (Vec<BoardMeta>, String) {
        let msg = self.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
        let Msg::BoardList { boards, active } = msg else { unreachable!() };
        (boards, active)
    }

    pub fn recv_restore(&mut self) -> Restore {
        Restore::from(self.recv_until("restore", |m| matches!(m, Msg::Restore { .. })))
    }

    pub fn recv_restore_for(&mut self, board: &str) -> Restore {
        Restore::from(self.recv_until(&format!("restore for {board}"), |m| {
            matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some(board))
        }))
    }

    pub fn recv_doc_opened(&mut self) -> DocEntry {
        let msg = self.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));
        let Msg::DocOpened(entry) = msg else { unreachable!() };
        entry
    }

    pub fn recv_doc_opened_for(&mut self, path: &str) -> DocEntry {
        let msg = self.recv_until(&format!("doc_opened for {path}"), |m| {
            matches!(m, Msg::DocOpened(e) if e.path == path)
        });
        let Msg::DocOpened(entry) = msg else { unreachable!() };
        entry
    }

    /// The `mtime_ms` of the next file_event for `path`.
    pub fn recv_file_event_for(&mut self, path: &str) -> u64 {
        let msg = self.recv_until(&format!("file_event for {path}"), |m| is_file_event_for(m, path));
        let Msg::FileEvent { mtime_ms, .. } = msg else { unreachable!() };
        mtime_ms
    }

    /// Like `recv_file_event_for`, but skips events older than `min_mtime_ms`.
    pub fn recv_file_event_since(&mut self, path: &str, min_mtime_ms: u64) -> u64 {
        let msg = self.recv_until(&format!("file_event for {path} since {min_mtime_ms}"), |m| {
            matches!(m, Msg::FileEvent { path: p, mtime_ms } if p == path && *mtime_ms >= min_mtime_ms)
        });
        let Msg::FileEvent { mtime_ms, .. } = msg else { unreachable!() };
        mtime_ms
    }

    /// The next exit of any term: `(term_id, code)`.
    pub fn recv_exit(&mut self) -> (String, Option<i64>) {
        let msg = self.recv_until("exit", |m| matches!(m, Msg::Exit { .. }));
        let Msg::Exit { term_id, code } = msg else { unreachable!() };
        (term_id, code)
    }

    /// Waits for a single output chunk of `term_id` that contains `needle`.
    pub fn recv_output_containing(&mut self, term_id: &str, needle: &str) {
        self.recv_until(&format!("output containing {needle:?}"), |m| {
            matches!(m, Msg::Output { term_id: t, bytes } if t == term_id && contains(bytes, needle.as_bytes()))
        });
    }

    /// Echo `marker` through a live `cat` and wait until the daemon has seen it, so
    /// the term's scrollback ring is known to hold it.
    pub fn echo_marker(&mut self, term_id: &str, marker: &str) {
        self.send(&Msg::Input { term_id: term_id.into(), bytes: format!("{marker}\n").into_bytes() });
        self.recv_output_containing(term_id, marker);
    }

    /// Appends `term_id`'s output to `collected` until it contains `needle`;
    /// other terms' frames and every Exit are skipped.
    pub fn collect_output_into(&mut self, collected: &mut Vec<u8>, term_id: &str, what: &str, needle: &[u8]) {
        let deadline = Instant::now() + LONG;
        while !contains(collected, needle) {
            if let Msg::Output { term_id: t, bytes } = self.recv(deadline, what)
                && t == term_id
            {
                collected.extend_from_slice(&bytes);
            }
        }
    }

    pub fn spawn_term(&mut self, term_id: &str, cmd: &[&str]) {
        self.spawn_term_with(term_id, cmd, Spawn::default());
    }

    pub fn spawn_term_with(&mut self, term_id: &str, cmd: &[&str], opts: Spawn) {
        self.send(&Msg::SpawnTerm {
            term_id: term_id.into(),
            cols: opts.cols,
            rows: opts.rows,
            cwd: opts.cwd,
            cmd: Some(cmd.iter().map(|s| s.to_string()).collect()),
            board_id: opts.board_id,
            inherit_cwd_from: opts.inherit_cwd_from,
        });
    }
}

/// The `spawn_term` fields a test seldom sets. The default is an 80x24 pty on the
/// active board with no cwd.
pub struct Spawn {
    pub cols: u16,
    pub rows: u16,
    pub cwd: Option<String>,
    pub board_id: Option<String>,
    pub inherit_cwd_from: Option<String>,
}

impl Spawn {
    pub fn on_board(board_id: &str) -> Self {
        Spawn { board_id: Some(board_id.into()), ..Default::default() }
    }
}

impl Default for Spawn {
    fn default() -> Self {
        Spawn { cols: 80, rows: 24, cwd: None, board_id: None, inherit_cwd_from: None }
    }
}

pub struct Restore {
    pub board_id: Option<String>,
    pub docs: Vec<DocEntry>,
    pub tiles: Vec<Tile>,
    pub board: Option<BoardViewport>,
    pub live_terms: Vec<String>,
}

impl From<Msg> for Restore {
    fn from(msg: Msg) -> Self {
        let Msg::Restore { board_id, docs, tiles, board, live_terms } = msg else {
            panic!("expected restore, got {msg:?}")
        };
        Restore { board_id, docs, tiles, board, live_terms }
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

pub fn is_file_event_for(msg: &Msg, want: &str) -> bool {
    matches!(msg, Msg::FileEvent { path, .. } if path == want)
}

/// Appends `bytes`, which bumps the mtime and produces a watcher event.
pub fn append_to(path: impl AsRef<Path>, bytes: &[u8]) {
    let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    f.write_all(bytes).unwrap();
    f.sync_all().unwrap();
}

pub fn touch(path: impl AsRef<Path>) {
    append_to(path, b"\n");
}

/// The file's mtime, truncated exactly as the daemon truncates it for a file_event.
pub fn mtime_ms(path: impl AsRef<Path>) -> u64 {
    std::fs::metadata(path)
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Lets the watcher go quiet before an edit: a watch that was just attached, or
/// events that are still in flight.
pub fn settle() {
    std::thread::sleep(Duration::from_millis(300));
}

pub fn doc_entry(v: &serde_json::Value, board: usize, path: &str) -> serde_json::Value {
    v["boards"][board]["docs"]
        .as_array()
        .and_then(|docs| docs.iter().find(|e| e["path"] == serde_json::json!(path)))
        .cloned()
        .unwrap_or(serde_json::Value::Null)
}

pub fn has_doc(v: &serde_json::Value, board: usize, path: &str) -> bool {
    !doc_entry(v, board, path).is_null()
}

// persist.rs writes `docs` in dock order, so a doc's index is its dock slot.
pub fn dock_index(v: &serde_json::Value, board: usize, path: &str) -> Option<usize> {
    v["boards"][board]["docs"]
        .as_array()?
        .iter()
        .position(|e| e["path"] == serde_json::json!(path))
}

pub fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
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
