// Shared harness: run the `tarmac` binary and capture what it printed.
#![allow(dead_code)] // each test binary uses a different slice of the harness

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg};

mod double;
pub mod frames;
pub use double::{Double, Peer};

/// The line of a verb whose daemon does not answer in time.
pub const NO_ANSWER: &str = "tarmac: no answer from the daemon in 5 s (an older daemon)\n";

/// Reads the `hello` and writes `hello_ok`, `late` after it, then reads the
/// request. False when the client went away first.
pub fn handshake(peer: &mut Peer, late: Duration) -> bool {
    let hello_ok = proto::encode(&hello_ok(None, None, None, None)).unwrap();
    if peer.read().is_none() {
        return false;
    }
    std::thread::sleep(late);
    peer.write(&hello_ok) && peer.read().is_some()
}

/// The line of a verb that finds no daemon on `sock`.
pub fn no_daemon_line(sock: &Path) -> String {
    format!("tarmac: no tarmac daemon running ({} channel, socket: {})\n", channel(), sock.display())
}

/// `tarmac <verb> <args>` on a socket that is absent: a run that tried to
/// connect would print the no-daemon line instead of the one asserted.
pub fn without_daemon(verb: &str, term_id: Option<&str>, args: &[&str]) -> Report {
    let mut cmd = tarmac();
    cmd.env_remove("TARMAC_TERM_ID");
    if let Some(term_id) = term_id {
        cmd.env("TARMAC_TERM_ID", term_id);
    }
    Report::of(cmd.arg(verb).args(args))
}

/// Exit 2 with the verb's one usage line.
#[track_caller]
pub fn assert_usage(out: &Report, verb: &str) {
    assert_eq!(out.code(), Some(2), "{}", out.stderr);
    assert!(out.one_stderr_line().starts_with(&format!("tarmac: usage: tarmac {verb}")), "{}", out.stderr);
}

/// Exit 1 with the no-answer line, no sooner than 5 s after `started`.
#[track_caller]
pub fn assert_no_answer(out: &Report, started: Instant) {
    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NO_ANSWER));
    assert!(started.elapsed() >= Duration::from_secs(5), "gave up after {:?}", started.elapsed());
}

/// What a `OneAnswer` double does with the frame after the hello.
pub enum Answer {
    Reply(Msg),
    /// Never answers.
    Silence,
}

/// A daemon double for a verb that sends one frame after its hello and waits
/// for the answer: `report` and `resume`.
pub struct OneAnswer {
    pub double: Double,
}

impl OneAnswer {
    pub fn start(answer: Answer) -> Self {
        let double = Double::start("tarmacd.sock", move |peer| {
            if !handshake(peer, Duration::ZERO) {
                return;
            }
            match answer {
                Answer::Reply(msg) => {
                    peer.write(&proto::encode(&msg).unwrap());
                    peer.drain();
                }
                Answer::Silence => peer.hold(),
            }
        });
        OneAnswer { double }
    }

    pub fn acking() -> Self {
        OneAnswer::start(Answer::Reply(Msg::Ack))
    }

    /// `tarmac <verb> <args>` in terminal t9.
    pub fn run(&self, verb: &str, args: &[&str]) -> Report {
        Report::of(tarmac_at(&self.double.sock).env("TARMAC_TERM_ID", "t9").arg(verb).args(args))
    }

    /// The raw payload of the one frame after the `hello`, which is checked.
    pub fn sent(&self) -> Vec<u8> {
        let frames = self.double.frames();
        let (hello, rest) = frames.split_first().expect("a hello");
        assert!(matches!(proto::decode(hello).unwrap(), Msg::Hello { .. }), "the first frame is the hello");
        assert_eq!(rest.len(), 1, "one frame after the hello");
        rest[0].clone()
    }
}

/// What a `Streamer` double does after the request.
pub enum Step {
    Write(Msg),
    Pause(Duration),
}

/// What a `Streamer` does once its steps are done.
pub enum Then {
    Close,
    Hold,
}

/// A daemon double for a verb that sends one request after its hello and
/// reads frames until it ends: `events`, `wait` and `terms`.
pub struct Streamer {
    pub double: Double,
}

impl Streamer {
    pub fn start(steps: Vec<Step>, then: Then) -> Self {
        Streamer::start_late(Duration::ZERO, steps, then)
    }

    /// `start`, with the `hello_ok` written `late`: a slow handshake.
    pub fn start_late(late: Duration, steps: Vec<Step>, then: Then) -> Self {
        let double = Double::start("tarmacd.sock", move |peer| {
            if !handshake(peer, late) {
                return;
            }
            for step in steps {
                match step {
                    Step::Write(msg) => {
                        if !peer.write(&proto::encode(&msg).unwrap()) {
                            return;
                        }
                    }
                    Step::Pause(wait) => std::thread::sleep(wait),
                }
            }
            if let Then::Hold = then {
                peer.hold();
            }
        });
        Streamer { double }
    }

    /// Writes `frames`, then closes.
    pub fn writing(frames: Vec<Msg>) -> Self {
        Streamer::start(frames.into_iter().map(Step::Write).collect(), Then::Close)
    }

    pub fn run(&self, args: &[&str]) -> Report {
        Report::of(tarmac_at(&self.double.sock).args(args))
    }

    /// The request after the `hello`, decoded, and its raw payload. Read
    /// with no join: a double that holds keeps its thread to its drop, and
    /// the request was read before any frame the cli got.
    pub fn request(&self) -> (Msg, Vec<u8>) {
        let frames = self.double.received.lock().unwrap().clone();
        let raw = frames.get(1).expect("a request after the hello").clone();
        (proto::decode(&raw).unwrap(), raw)
    }
}

/// True when nothing reached the double: no hello, so no connection.
pub fn untouched(double: &Double) -> bool {
    double.received.lock().unwrap().is_empty()
}

/// `cmd` started with its stdout and stderr piped, for a test that acts while
/// it runs; through the same lock as every other spawn (#190).
pub fn start(cmd: &mut Command) -> Child {
    spawn(cmd, Stdio::null())
}

pub fn hello_ok(
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

/// Pinned to an absent socket so no test can reach a real daemon; a test that
/// needs one sets its own `TARMAC_SOCKET`.
pub fn tarmac() -> Command {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_tarmac"));
    cmd.env("TARMAC_SOCKET", std::env::temp_dir().join(format!("tarmac-cli-test-{}-absent.sock", std::process::id())));
    cmd
}

/// `tarmac`, on the socket `sock`.
pub fn tarmac_at(sock: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut cmd = tarmac();
    cmd.env("TARMAC_SOCKET", sock);
    cmd
}

/// The channel this test binary's build config implies — the same mapping the
/// CLI uses, so `cargo test --release` cannot make these tests lie.
pub fn channel() -> &'static str {
    if cfg!(debug_assertions) { "dev" } else { "release" }
}

static SPAWN: Mutex<()> = Mutex::new(());

/// `Command::spawn`, one child at a time. On macOS std marks a child's pipes
/// close-on-exec in a second step, so a sibling test spawning in between hands
/// them to its own child and EOF waits for THAT child's exit (#190).
fn spawn(cmd: &mut Command, stdin: Stdio) -> Child {
    let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
    cmd.stdin(stdin).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap()
}

/// The captured result of one run of the binary.
pub struct Report {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

impl Report {
    pub fn of(cmd: &mut Command) -> Self {
        Report::with_stdin(cmd, Stdio::null())
    }

    /// `of`, with `stdin` for the child's stdin: a file, or a directory, whose
    /// reads fail.
    pub fn with_stdin(cmd: &mut Command, stdin: impl Into<Stdio>) -> Self {
        Report::from(spawn(cmd, stdin.into()).wait_with_output().unwrap())
    }

    /// `of`, with `input` piped to the child's stdin from a thread of its own,
    /// which closes the pipe after it. A child that exits first ends the write.
    pub fn of_input(cmd: &mut Command, input: Vec<u8>) -> Self {
        let mut child = spawn(cmd, Stdio::piped());
        let mut stdin = child.stdin.take().unwrap();
        let writer = std::thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
        let out = child.wait_with_output().unwrap();
        writer.join().unwrap();
        Report::from(out)
    }

    /// `of`, with a pipe on the child's stdin that this end keeps open and
    /// writes nothing to. `None` when the child has not exited `within`; it
    /// is killed then.
    pub fn with_open_stdin(cmd: &mut Command, within: Duration) -> Option<Self> {
        let mut child = spawn(cmd, Stdio::piped());
        let _open = child.stdin.take();
        let deadline = Instant::now() + within;
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        Some(Report::from(child.wait_with_output().unwrap()))
    }

    pub fn code(&self) -> Option<i32> {
        self.status.code()
    }

    /// Asserts stderr is exactly one line and returns it for further checks.
    #[track_caller]
    pub fn one_stderr_line(&self) -> &str {
        assert_eq!(self.stderr.lines().count(), 1, "expected one line, got: {}", self.stderr);
        &self.stderr
    }
}

impl From<Output> for Report {
    fn from(out: Output) -> Self {
        Report {
            status: out.status,
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
    }
}

static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

/// A per-test temp dir, reset on entry so a rerun never inherits the last run's
/// files. Named so concurrently-running tests cannot collide.
pub fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-cli-test-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
