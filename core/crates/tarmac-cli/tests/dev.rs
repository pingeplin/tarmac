// `tarmac dev` (spec 2609.0015) against a fake app endpoint: a scratch unix
// socket that speaks the dev framing and replies exactly what each test
// prescribes. The CLI's whole contract here is argv in, one frame out, one frame
// back, `body` printed verbatim, exit code from `ok` — none of which needs a real
// app, and several of which a real app reaches only rarely (a body that is not
// JSON, a reply that takes 5.5 s, silence).

use std::io::Read;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use tarmac_protocol::{dev, frame};

fn tarmac() -> Command {
    Command::new(env!("CARGO_BIN_EXE_tarmac"))
}

static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-dev-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

enum Reply {
    /// Frame this reply back immediately.
    Now(dev::DevReply),
    /// Read the request, wait, then reply — the only way to exercise the CLI's
    /// read deadline from the slow-but-healthy side.
    After(Duration, dev::DevReply),
    /// Read the request and never reply. Outlives any deadline under test.
    Silence,
}

struct Fake {
    sock: PathBuf,
    received: Arc<Mutex<Vec<Vec<u8>>>>,
    server: Mutex<Option<JoinHandle<()>>>,
    _dir: PathBuf,
}

impl Fake {
    fn start(reply: Reply) -> Self {
        let dir = scratch();
        let sock = dir.join("tarmac-dev.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let received = Arc::new(Mutex::new(Vec::new()));

        let rx = received.clone();
        let server = std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else { return };
            if let Ok(payload) = frame::read_sync(&mut stream) {
                rx.lock().unwrap().push(payload);
            }
            let reply = match reply {
                // Never joined (that is the point); the thread dies with the
                // test process.
                Reply::Silence => {
                    std::thread::sleep(Duration::from_secs(30));
                    return;
                }
                Reply::After(d, reply) => {
                    std::thread::sleep(d);
                    reply
                }
                Reply::Now(reply) => reply,
            };
            let payload = dev::encode_reply(&reply).unwrap();
            if frame::write_sync(&mut stream, &payload).is_err() {
                return;
            }
            // Keep reading so the test can observe whether the CLI sends anything
            // after its one request. EOF (the CLI exiting) ends the loop.
            stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            let mut sink = Vec::new();
            let _ = stream.read_to_end(&mut sink);
            if !sink.is_empty() {
                rx.lock().unwrap().push(sink);
            }
        });
        Fake { sock, received, server: Mutex::new(Some(server)), _dir: dir }
    }

    fn run(&self, args: &[&str]) -> std::process::Output {
        tarmac().env("TARMAC_DEV_SOCKET", &self.sock).arg("dev").args(args).output().unwrap()
    }

    /// Wait for the server thread, so `received` is complete rather than whatever
    /// had arrived by the time the client exited.
    fn frames(&self) -> Vec<Vec<u8>> {
        if let Some(h) = self.server.lock().unwrap().take() {
            let _ = h.join();
        }
        self.received.lock().unwrap().clone()
    }
}

fn ok_reply(body: &str) -> dev::DevReply {
    dev::DevReply { ok: true, body: body.into() }
}

/// S59 — a successful reply: exit 0, body on stdout with exactly one newline,
/// stderr empty.
#[test]
fn a_successful_reply_goes_to_stdout_and_exits_zero() {
    let fake = Fake::start(Reply::Now(ok_reply("{\"v\":1}")));
    let out = fake.run(&["snapshot"]);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "{\"v\":1}\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "");
}

/// S60 — a failing reply: exit 1, body on STDERR, stdout untouched, so
/// `tarmac dev snapshot | jq` is never fed an error object.
#[test]
fn a_failing_reply_goes_to_stderr_and_exits_one() {
    let body = "{\"error\":\"no_such_card\",\"card\":\"t-9\"}";
    let fake = Fake::start(Reply::Now(dev::DevReply { ok: false, body: body.into() }));
    let out = fake.run(&["focus", "t-9"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    assert_eq!(String::from_utf8_lossy(&out.stderr), format!("{body}\n"));
}

/// S61 — `body` is opaque. A body that is not JSON prints verbatim and the exit
/// code still follows `ok`; the CLI never parses it, which is what keeps this
/// crate std-only.
#[test]
fn the_body_is_never_parsed() {
    let fake = Fake::start(Reply::Now(ok_reply("not json at all")));
    let out = fake.run(&["snapshot"]);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "not json at all\n");

    let fake = Fake::start(Reply::Now(dev::DevReply { ok: false, body: "also not json".into() }));
    let out = fake.run(&["snapshot"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&out.stderr), "also not json\n");
}

/// S62 — no listener: exit 1 and ONE line of plain text naming the path. This is
/// the CLI's own error, not the app's, so it is not JSON.
#[test]
fn no_listener_is_a_clear_one_line_error() {
    let dir = scratch();
    let sock = dir.join("absent.sock");
    let out = tarmac()
        .env("TARMAC_DEV_SOCKET", &sock)
        .args(["dev", "snapshot"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(err.lines().count(), 1, "expected one line, got: {err}");
    assert!(err.contains(sock.to_str().unwrap()), "error does not name the path: {err}");
    assert!(!err.contains('{'), "CLI-side errors are plain text, got: {err}");
}

/// S63 — exactly one frame leaves the CLI, and it is the request.
#[test]
fn exactly_one_request_frame_is_sent() {
    let fake = Fake::start(Reply::Now(ok_reply("{}")));
    let out = fake.run(&["focus", "t-1"]);
    assert_eq!(out.status.code(), Some(0));
    let frames = fake.frames();
    assert_eq!(frames.len(), 1, "expected exactly one frame, got {}", frames.len());
    assert_eq!(
        dev::decode_request(&frames[0]).unwrap(),
        dev::DevRequest::Focus { card: Some("t-1".into()) },
    );
}

/// S64 — an over-long socket path is refused before anything is dialled.
#[test]
fn an_over_long_socket_path_is_refused_before_dialling() {
    let fake = Fake::start(Reply::Now(ok_reply("{}")));
    let long = PathBuf::from(format!("/tmp/{}.sock", "x".repeat(110)));
    assert!(long.as_os_str().len() >= 104);
    let out = tarmac()
        .env("TARMAC_DEV_SOCKET", &long)
        .args(["dev", "snapshot"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("104"));
    // The fake at the short path was never dialled.
    assert!(fake.received.lock().unwrap().is_empty());
}

/// S73(b) — the load-bearing half. The CLI's read deadline is the app's budget
/// plus 3 s, so a healthy app that takes 5.5 s to answer `--timeout 10000` is
/// still heard. An implementation that reuses the handshake path's fixed 5 s
/// passes S73(a) and fails here.
#[test]
fn a_slow_but_healthy_app_is_still_heard() {
    let fake = Fake::start(Reply::After(Duration::from_millis(5_500), ok_reply("{\"v\":1}")));
    let out = fake.run(&["snapshot", "--timeout", "10000"]);
    assert_eq!(out.status.code(), Some(0), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "{\"v\":1}\n");
}

/// S73(b) — and the deadline really is a deadline. With `--timeout 100` the CLI
/// gives up at 3.1 s; the 4 s bound is deliberately below a hard-coded 5 s
/// timeout's return, which "under 5 s" would sit exactly on.
#[test]
fn a_silent_app_is_given_up_on_within_the_deadline() {
    let fake = Fake::start(Reply::Silence);
    let started = Instant::now();
    let out = fake.run(&["snapshot", "--timeout", "100"]);
    let elapsed = started.elapsed();
    assert_eq!(out.status.code(), Some(1));
    assert!(elapsed < Duration::from_secs(4), "took {elapsed:?}");
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(err.lines().count(), 1, "expected one line, got: {err}");
    assert!(!err.contains('{'), "CLI-side errors are plain text, got: {err}");
}

/// S58 — `--help` documents the family, the dev-build gate, and the notes that are
/// otherwise folklore. This suite only ever runs in a debug build, which is the
/// build that should document it; that a RELEASE `--help` says nothing about `dev`
/// is Q1's to observe, and it does.
///
/// The needle list is also what discharges the DOCS half of S12c, S16 and S77.
/// Each of those scenarios asks for a statement in the help text as well as a
/// plan — what `alt+tab` does to focus, what `contextmenu` leaves behind, and what
/// kitty flag 8 does to `type` — and a kit test cannot see whether the statement
/// was ever written. Without these rows the whole block could be deleted and
/// `make test` would stay green.
#[test]
fn help_documents_the_dev_family_and_its_limits() {
    let out = tarmac().arg("--help").output().unwrap();
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    for needle in [
        "tarmac dev snapshot",
        "tarmac dev zoom",
        "tarmac dev focus",
        "dev builds only",
        "TARMAC_DEV_SOCKET",
        "⌘C",
        "Edit-menu",
        "bare printable",
        "mouse reporting",
        // S12c: alt+tab cycles the prime terminal and takes focus with it.
        "alt+tab",
        "not_focused",
        // S16: what the right-click leaves behind.
        "contextmenu",
        "helper textarea",
        // S77: the kitty flag 8 consequence for `type`.
        "kitty flag",
        "mode: key",
    ] {
        assert!(text.contains(needle), "--help does not mention {needle:?}");
    }
}
