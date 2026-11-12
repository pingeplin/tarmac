// Shared harness: run the `tarmac` binary and capture what it printed.
#![allow(dead_code)] // each test binary uses a different slice of the harness

use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg};

mod double;
pub use double::Double;

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
