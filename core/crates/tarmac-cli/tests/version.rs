// `tarmac --version` (spec 2609.0012) against a fake daemon: a scratch unix
// socket that speaks the wire protocol and replies exactly what each test
// prescribes. Nothing here needs a real tarmacd — the CLI's contract is what it
// renders from a `hello_ok`, and a fake is the only way to drive the states a
// real daemon reaches rarely (a version-less app, a pre-key daemon, silence).

use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use tarmac_protocol::{self as proto, Msg, frame};

fn tarmac() -> Command {
    Command::new(env!("CARGO_BIN_EXE_tarmac"))
}

static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-version-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// What the fake daemon does after reading the client's `hello`.
enum Reply {
    /// Frame this message back, then keep reading so the test can observe
    /// whether the client sends anything else.
    Frame(Msg),
    /// Accept, then drop the connection without replying.
    CloseWithoutReply,
    /// Accept and hold the connection open, never replying — the only way to
    /// exercise the client's read timeout.
    Silence,
}

struct Fake {
    sock: PathBuf,
    /// Raw payloads received, in order. Raw (not decoded) so a test can assert
    /// which keys were on the wire, not just what they decoded to.
    received: Arc<Mutex<Vec<Vec<u8>>>>,
    server: Mutex<Option<JoinHandle<()>>>,
    dir: PathBuf,
}

impl Fake {
    fn start(reply: Reply) -> Self {
        let dir = scratch();
        let sock = dir.join("tarmacd.sock");
        let listener = UnixListener::bind(&sock).unwrap();
        let received = Arc::new(Mutex::new(Vec::new()));

        let rx = received.clone();
        let server = std::thread::spawn(move || {
            let Ok((mut stream, _)) = listener.accept() else { return };
            if let Ok(payload) = frame::read_sync(&mut stream) {
                rx.lock().unwrap().push(payload);
            }
            match reply {
                Reply::CloseWithoutReply => return,
                // Outlives the client's 5s read timeout without ever replying.
                // Never joined (that is the point); the thread dies with the
                // test process.
                Reply::Silence => std::thread::sleep(Duration::from_secs(30)),
                Reply::Frame(msg) => {
                    let payload = proto::encode(&msg).unwrap();
                    if frame::write_sync(&mut stream, &payload).is_err() {
                        return;
                    }
                    stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
                    while let Ok(p) = frame::read_sync(&mut stream) {
                        rx.lock().unwrap().push(p);
                    }
                }
            }
        });
        Fake { sock, received, server: Mutex::new(Some(server)), dir }
    }

    /// Wait for the server thread to finish reading, so `received` is complete
    /// rather than whatever had arrived by the time the client exited.
    fn received_frames(&self) -> Vec<Vec<u8>> {
        if let Some(handle) = self.server.lock().unwrap().take() {
            handle.join().unwrap();
        }
        self.received.lock().unwrap().clone()
    }

    fn version(&self) -> Report {
        Report::of(tarmac().env("TARMAC_SOCKET", &self.sock).arg("--version"))
    }
}

/// The captured result of one `tarmac --version` run.
struct Report {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl Report {
    fn of(cmd: &mut Command) -> Self {
        let out = cmd.output().unwrap();
        Report {
            code: out.status.code(),
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }

    /// The value after the 8-column label field, for one label.
    fn line(&self, label: &str) -> String {
        let prefix = format!("{label:<8} ");
        self.stdout
            .lines()
            .find_map(|l| l.strip_prefix(&prefix))
            .unwrap_or_else(|| panic!("no `{label}` line in:\n{}", self.stdout))
            .to_string()
    }
}

/// The channel this test binary's build config implies — the same mapping the
/// CLI uses, so `cargo test --release` cannot make these tests lie.
fn expected_channel() -> &'static str {
    if cfg!(debug_assertions) { "dev" } else { "release" }
}

fn hello_ok(
    daemon_version: Option<&str>,
    daemon_pid: Option<u32>,
    app_version: Option<&str>,
    app_connected: Option<bool>,
) -> Msg {
    Msg::HelloOk {
        v: proto::PROTOCOL_VERSION,
        daemon_version: daemon_version.map(str::to_string),
        daemon_pid,
        app_version: app_version.map(str::to_string),
        app_connected,
    }
}

/// A daemon reporting sentinel values unlike any real release, so no assertion
/// can pass by coincidence.
fn full_reply() -> Msg {
    hello_ok(Some("9.9.9"), Some(4242), Some("8.8.8"), Some(true))
}

// S10 / S11 / S23: the whole report, byte-for-byte. The cli line carries this
// binary's real version — which differs from the daemon's 9.9.9, so the skew
// this verb exists to expose is visible in the output itself.
#[test]
fn the_report_is_five_exact_lines() {
    let fake = Fake::start(Reply::Frame(full_reply()));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.stderr, "", "the report goes to stdout only");
    assert_eq!(
        report.stdout,
        format!(
            "cli      {}\ndaemon   9.9.9 (pid 4242)\napp      8.8.8 (running)\nchannel  {}\nsocket   {}\n",
            env!("CARGO_PKG_VERSION"),
            expected_channel(),
            fake.sock.display()
        )
    );
    assert_ne!(
        env!("CARGO_PKG_VERSION"),
        "9.9.9",
        "the fixture must differ from the real version or skew is untestable"
    );
}

// S12: an observed-absent app renders as absent — and no digit of the daemon's
// version leaks onto the app line.
#[test]
fn an_absent_app_is_reported_as_not_connected() {
    let fake = Fake::start(Reply::Frame(hello_ok(Some("9.9.9"), Some(4242), None, Some(false))));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.line("app"), "not connected");
}

// S32: the case app_connected exists for. An app that reported no version is
// still an observed app; rendering it as absent would be the false negative
// this whole feature exists to prevent. An implementation that ignores
// app_connected passes the test above and fails this one.
#[test]
fn a_connected_app_that_reported_no_version_is_not_called_absent() {
    let fake = Fake::start(Reply::Frame(hello_ok(Some("9.9.9"), Some(4242), None, Some(true))));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.line("app"), "connected (version not reported)");
}

// S33: a daemon older than these keys — the motivating skew itself, a freshly
// upgraded CLI against a still-running old daemon. Its version is still
// reported; the app is neither invented nor declared absent.
#[test]
fn a_pre_key_daemon_yields_an_unknown_app_not_an_absent_one() {
    let fake = Fake::start(Reply::Frame(hello_ok(Some("0.10.0"), Some(8275), None, None)));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.line("daemon"), "0.10.0 (pid 8275)");
    assert_eq!(report.line("app"), "unknown (daemon predates this key)");
}

// S17: a missing daemon version does not suppress the app line.
#[test]
fn a_version_less_daemon_still_reports_its_app() {
    let fake = Fake::start(Reply::Frame(hello_ok(None, Some(4242), Some("8.8.8"), Some(true))));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.line("daemon"), "connected (version not reported)");
    assert_eq!(report.line("app"), "8.8.8 (running)");
}

// S29: a pre-`daemon_pid` daemon renders no empty `(pid )` suffix.
#[test]
fn a_pid_less_daemon_renders_the_version_alone() {
    let fake = Fake::start(Reply::Frame(hello_ok(Some("9.9.9"), None, None, Some(false))));

    assert_eq!(fake.version().line("daemon"), "9.9.9");
}

// S16: a rejected handshake is still exit 0, and a multi-line rejection is
// flattened so the report stays five lines.
#[test]
fn a_rejected_handshake_is_reported_not_fatal() {
    let fake = Fake::start(Reply::Frame(Msg::Err { msg: "go away\nnow".into() }));
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert_eq!(report.stdout.lines().count(), 5, "got:\n{}", report.stdout);
    let daemon = report.line("daemon");
    assert!(daemon.starts_with("unreachable ("), "got: {daemon}");
    assert!(daemon.contains("go away now"), "newlines must flatten: {daemon}");
    assert_eq!(report.line("app"), "unknown (daemon unreachable)");
}

// S25: a peer that accepts and hangs up without replying is unreachable, not
// absent — something was listening.
#[test]
fn a_peer_that_closes_without_replying_is_unreachable() {
    let fake = Fake::start(Reply::CloseWithoutReply);
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert!(report.line("daemon").starts_with("unreachable ("));
    assert_eq!(report.line("app"), "unknown (daemon unreachable)");
}

// S34: the read timeout. The only failure mode where a bug hangs the CLI
// forever instead of printing something wrong, so it is worth its ~5s.
#[test]
fn a_silent_peer_times_out_instead_of_hanging() {
    let fake = Fake::start(Reply::Silence);
    let started = std::time::Instant::now();
    let report = fake.version();

    assert_eq!(report.code, Some(0));
    assert!(report.line("daemon").starts_with("unreachable ("));
    assert!(started.elapsed() < Duration::from_secs(15), "must not hang: {:?}", started.elapsed());
}

// S24: the CLI names itself `cli`, never stamps app_version (that key belongs
// to the app alone), and sends nothing after the handshake.
#[test]
fn the_cli_sends_exactly_one_version_less_hello() {
    let fake = Fake::start(Reply::Frame(full_reply()));
    assert_eq!(fake.version().code, Some(0));

    let received = fake.received_frames();
    assert_eq!(received.len(), 1, "--version must send exactly one frame");
    assert_eq!(
        proto::decode(&received[0]).unwrap(),
        Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION, app_version: None }
    );
    assert!(
        !received[0].windows(11).any(|w| w == b"app_version"),
        "the cli must not put app_version on the wire at all"
    );
}

// S13 / S14: no daemon is exit 0 — unlike `open` — and the report still names
// the channel and socket it resolved, which is what makes a shadowing dev CLI
// pointed at the wrong socket self-evident.
#[test]
fn no_daemon_still_reports_the_cli_channel_and_socket() {
    let dir = scratch();
    let sock = dir.join("absent.sock");
    let report = Report::of(tarmac().env("TARMAC_SOCKET", &sock).arg("--version"));

    assert_eq!(report.code, Some(0));
    assert_eq!(report.stderr, "");
    assert_eq!(report.line("cli"), env!("CARGO_PKG_VERSION"));
    assert_eq!(report.line("daemon"), "not running");
    assert_eq!(report.line("app"), "unknown (no daemon)");
    assert_eq!(report.line("channel"), expected_channel());
    assert_eq!(report.line("socket"), sock.display().to_string());
}

// S15: an over-long socket path is a misconfiguration, not an absent daemon —
// nothing was ever dialled, so "not running" would be a claim about a process
// the CLI never observed. `open` errors out here; `--version` must not.
#[test]
fn an_over_long_socket_path_is_unreachable_not_absent() {
    let dir = scratch();
    let sock = dir.join(format!("{}.sock", "s".repeat(120)));
    assert!(sock.as_os_str().len() >= 104, "fixture must exceed the sun_path cap");
    let report = Report::of(tarmac().env("TARMAC_SOCKET", &sock).arg("--version"));

    assert_eq!(report.code, Some(0));
    assert!(report.line("daemon").starts_with("unreachable ("), "got: {}", report.line("daemon"));
    assert_eq!(report.line("app"), "unknown (daemon unreachable)");
    assert_eq!(report.line("socket"), sock.display().to_string());
}

// S26: wrong arity stays a usage error, like every other verb.
#[test]
fn extra_arguments_are_a_usage_error() {
    let out = tarmac().args(["--version", "extra"]).output().unwrap();

    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "", "a usage error prints no report");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("usage"),
        "a usage error must say so on stderr, like every other verb"
    );
}

// S18: --help carries the verb and its exit-status exception.
#[test]
fn help_lists_the_version_verb_and_its_exit_status() {
    let out = tarmac().arg("--help").output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);

    assert!(out.status.success());
    assert!(text.contains("tarmac --version"));
    assert!(
        text.contains("0  success; also `tarmac --version` with no daemon running"),
        "EXIT STATUS must state that --version exits 0 without a daemon:\n{text}"
    );
}

// S27: the handshake was extracted out of `open`, so `open`'s reject path needs
// re-pinning — it must still be exit 1 with the same one-line message.
#[test]
fn open_still_fails_on_a_rejected_handshake() {
    let fake = Fake::start(Reply::Frame(Msg::Err { msg: "nope".into() }));
    let doc = fake.dir.join("doc.md");
    std::fs::write(&doc, "# hi\n").unwrap();

    let out = tarmac()
        .env("TARMAC_SOCKET", &fake.sock)
        .args(["open", doc.to_str().unwrap()])
        .output()
        .unwrap();

    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(err.lines().count(), 1, "expected one line, got: {err}");
    assert!(err.contains("daemon rejected handshake: nope"), "got: {err}");
}
