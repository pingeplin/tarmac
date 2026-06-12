// End-to-end M0 test: real daemon process on a temp socket, app + cli clients
// speaking the wire protocol over std unix sockets.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::{self as proto, Msg, frame};

const LONG: Duration = Duration::from_secs(20);

// Counter, not just a timestamp: parallel test threads can hit the same
// nanosecond and would then share (and tear down) each other's socket dir.
static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

fn temp_dir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-it-{}-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed),
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

struct TestDaemon {
    child: Child,
    dir: PathBuf,
    sock: PathBuf,
}

impl TestDaemon {
    fn start() -> Self {
        let dir = temp_dir();
        let sock = dir.join("tarmacd.sock");
        let child = spawn_daemon(&sock);
        wait_for_socket(&sock);
        TestDaemon { child, dir, sock }
    }
}

impl Drop for TestDaemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn spawn_daemon(sock: &Path) -> Child {
    Command::new(env!("CARGO_BIN_EXE_tarmacd"))
        .env("TARMAC_SOCKET", sock)
        .env("RUST_LOG", "debug")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn tarmacd")
}

fn wait_for_socket(sock: &Path) {
    let deadline = Instant::now() + LONG;
    while Instant::now() < deadline {
        if UnixStream::connect(sock).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("daemon socket never became connectable: {}", sock.display());
}

struct Conn(UnixStream);

impl Conn {
    fn connect(sock: &Path) -> Self {
        let stream = UnixStream::connect(sock).expect("connect");
        stream.set_write_timeout(Some(LONG)).unwrap();
        Conn(stream)
    }

    fn hello(sock: &Path, role: &str) -> Self {
        let mut conn = Conn::connect(sock);
        conn.send(&Msg::Hello { role: role.into(), v: proto::PROTOCOL_VERSION });
        let reply = conn.recv(Instant::now() + LONG, "hello_ok");
        assert!(matches!(reply, Msg::HelloOk { v: 1 }), "expected hello_ok, got {reply:?}");
        conn
    }

    fn send(&mut self, msg: &Msg) {
        let payload = proto::encode(msg).unwrap();
        frame::write_sync(&mut self.0, &payload).expect("write frame");
    }

    fn recv(&mut self, deadline: Instant, what: &str) -> Msg {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for {what}");
        self.0.set_read_timeout(Some(remaining)).unwrap();
        let payload = frame::read_sync(&mut self.0)
            .unwrap_or_else(|e| panic!("read frame while waiting for {what}: {e}"));
        proto::decode(&payload).expect("decode frame")
    }

    fn recv_until(&mut self, what: &str, mut pred: impl FnMut(&Msg) -> bool) -> Msg {
        let deadline = Instant::now() + LONG;
        loop {
            let msg = self.recv(deadline, what);
            if pred(&msg) {
                return msg;
            }
        }
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[test]
fn m0_end_to_end() {
    let daemon = TestDaemon::start();

    // --- app connect: hello_ok then restore (empty registry) ---
    let mut app = Conn::hello(&daemon.sock, "app");
    let restore = app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs } = restore else { unreachable!() };
    assert!(docs.is_empty(), "fresh daemon should restore zero docs, got {docs:?}");

    // --- spawn a term, expect output then exit 0 ---
    app.send(&Msg::SpawnTerm {
        term_id: "t1".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/echo".into(), "tarmac-test-ok".into()]),
    });
    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    loop {
        match app.recv(deadline, "echo output") {
            Msg::Output { term_id, bytes } if term_id == "t1" => {
                collected.extend_from_slice(&bytes);
                if contains(&collected, b"tarmac-test-ok") {
                    break;
                }
            }
            Msg::Exit { .. } => panic!(
                "exit before expected output; collected: {:?}",
                String::from_utf8_lossy(&collected)
            ),
            _ => {}
        }
    }
    let exit = app.recv_until("exit", |m| matches!(m, Msg::Exit { .. }));
    let Msg::Exit { term_id, code } = exit else { unreachable!() };
    assert_eq!(term_id, "t1");
    assert_eq!(code, Some(0));

    // --- cli open: ack + doc_opened pushed to the app ---
    let md_path = daemon.dir.join("note.md");
    std::fs::write(&md_path, "# tarmac\n").unwrap();
    let canon = std::fs::canonicalize(&md_path).unwrap();
    let canon_str = canon.to_string_lossy().into_owned();

    let mut cli = Conn::hello(&daemon.sock, "cli");
    cli.send(&Msg::Open { path: canon_str.clone() });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
    drop(cli);

    let doc = app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened { .. }));
    let Msg::DocOpened { path, via } = doc else { unreachable!() };
    assert_eq!(path, canon_str);
    assert_eq!(via, "cli");

    // --- append to the file: file_event with mtime arrives ---
    std::thread::sleep(Duration::from_millis(300)); // let the watch settle
    let mut f = std::fs::OpenOptions::new().append(true).open(&canon).unwrap();
    f.write_all(b"\nmore\n").unwrap();
    f.sync_all().unwrap();
    drop(f);

    let event = app.recv_until("file_event", |m| matches!(m, Msg::FileEvent { .. }));
    let Msg::FileEvent { path, mtime_ms } = event else { unreachable!() };
    assert_eq!(path, canon_str);
    assert!(mtime_ms > 0);

    // --- a second app connection replaces the first and restores the doc ---
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs } = restore else { unreachable!() };
    assert_eq!(docs.len(), 1);
    assert_eq!(docs[0].path, canon_str);
    assert_eq!(docs[0].via, "cli");
    assert!(docs[0].last_changed_ms.is_some());
}

#[test]
fn term_input_pty_size_and_exit_code() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    app.send(&Msg::SpawnTerm {
        term_id: "t2".into(),
        cols: 100,
        rows: 30,
        cwd: Some(daemon.dir.to_string_lossy().into_owned()),
        cmd: Some(vec![
            "/bin/sh".into(),
            "-c".into(),
            "stty size; read line; echo got-$line; exit 7".into(),
        ]),
    });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    while !contains(&collected, b"30 100") {
        if let Msg::Output { term_id, bytes } = app.recv(deadline, "stty size output")
            && term_id == "t2"
        {
            collected.extend_from_slice(&bytes);
        }
    }

    app.send(&Msg::Input { term_id: "t2".into(), bytes: b"ping\n".to_vec() });
    let deadline = Instant::now() + LONG;
    while !contains(&collected, b"got-ping") {
        if let Msg::Output { term_id, bytes } = app.recv(deadline, "echoed input")
            && term_id == "t2"
        {
            collected.extend_from_slice(&bytes);
        }
    }

    let exit = app.recv_until("exit", |m| matches!(m, Msg::Exit { .. }));
    let Msg::Exit { term_id, code } = exit else { unreachable!() };
    assert_eq!(term_id, "t2");
    assert_eq!(code, Some(7));
}

#[test]
fn open_errors_for_missing_or_relative_paths() {
    let daemon = TestDaemon::start();
    let mut cli = Conn::hello(&daemon.sock, "cli");

    cli.send(&Msg::Open { path: daemon.dir.join("nope.md").to_string_lossy().into_owned() });
    let reply = cli.recv(Instant::now() + LONG, "err for missing file");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");

    cli.send(&Msg::Open { path: "relative.md".into() });
    let reply = cli.recv(Instant::now() + LONG, "err for relative path");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");
}

#[test]
fn bad_role_is_rejected() {
    let daemon = TestDaemon::start();
    let mut conn = Conn::connect(&daemon.sock);
    conn.send(&Msg::Hello { role: "gremlin".into(), v: 1 });
    let reply = conn.recv(Instant::now() + LONG, "err for bad role");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");
}

#[test]
fn socket_claiming() {
    let dir = temp_dir();
    let sock = dir.join("tarmacd.sock");

    let mut first = spawn_daemon(&sock);
    wait_for_socket(&sock);

    // Second daemon against a live socket exits 1.
    let mut second = spawn_daemon(&sock);
    let deadline = Instant::now() + LONG;
    let status = loop {
        if let Some(status) = second.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "second daemon did not exit");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(status.code(), Some(1));

    // SIGKILL the live daemon: the socket file goes stale on disk.
    first.kill().unwrap();
    first.wait().unwrap();
    assert!(sock.exists(), "socket file should remain after SIGKILL");

    // A new daemon must unlink the stale socket and bind.
    let mut third = spawn_daemon(&sock);
    wait_for_socket(&sock);
    let _ = Conn::hello(&sock, "cli");

    let _ = third.kill();
    let _ = third.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
