// Shared harness: run the `tarmac` binary and capture what it printed.
#![allow(dead_code)] // each test binary uses a different slice of the harness

use std::path::PathBuf;
use std::process::{Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, PoisonError};

pub fn tarmac() -> Command {
    Command::new(env!("CARGO_BIN_EXE_tarmac"))
}

static SPAWN: Mutex<()> = Mutex::new(());

/// `Command::output`, spawning one child at a time. On macOS std marks a child's
/// output pipes close-on-exec in a second step, so a sibling test spawning in
/// between hands them to its own child and EOF waits for THAT child's exit (#190).
fn output(cmd: &mut Command) -> Output {
    let child = {
        let _spawning = SPAWN.lock().unwrap_or_else(PoisonError::into_inner);
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap()
    };
    child.wait_with_output().unwrap()
}

/// The captured result of one run of the binary.
pub struct Report {
    pub status: ExitStatus,
    pub stdout: String,
    pub stderr: String,
}

impl Report {
    pub fn of(cmd: &mut Command) -> Self {
        let out = output(cmd);
        Report {
            status: out.status,
            stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        }
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
