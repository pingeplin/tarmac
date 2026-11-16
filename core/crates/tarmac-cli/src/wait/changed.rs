use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use serde_json::json;

use super::Outcome;

/// The argument that runs `stat_helper`: internal, so not in `tarmac help`.
pub const STAT_HELPER: &str = "__wait-changed-stat";

/// One stat of the path: its identity, mtime and size, or that it is not
/// there. A change of `ino` or `dev` is a file replaced by a rename.
#[derive(Clone, Copy, Debug)]
enum Sample {
    Present { dev: u64, ino: u64, mtime_ns: i128, size: u64 },
    Missing,
}

fn poll_interval(elapsed: Duration) -> Duration {
    if elapsed < Duration::from_secs(2) { Duration::from_millis(100) } else { Duration::from_millis(250) }
}

/// True once the wait is over: a change seen, and `settle` passed since the
/// last one when it is given.
fn settled(last_change: Option<Instant>, settle: Option<Duration>, now: Instant) -> bool {
    match (last_change, settle) {
        (None, _) => false,
        (Some(_), None) => true,
        (Some(at), Some(settle)) => now.duration_since(at) >= settle,
    }
}

/// The stat follows a link. A path that is not there, or below a file, is
/// `Missing`; any other failure is the error.
fn sample(path: &Path) -> io::Result<Sample> {
    match std::fs::metadata(path) {
        Ok(m) => Ok(Sample::Present {
            dev: m.dev(),
            ino: m.ino(),
            mtime_ns: i128::from(m.mtime()) * 1_000_000_000 + i128::from(m.mtime_nsec()),
            size: m.size(),
        }),
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound | io::ErrorKind::NotADirectory) => Ok(Sample::Missing),
        Err(e) => Err(e),
    }
}

const MISSING: &str = "missing";
const STAT_ERROR: &str = "error ";

impl Sample {
    /// The helper's line for this sample. `wait` only compares lines, so the
    /// line is the sample's identity.
    fn line(&self) -> String {
        match self {
            Sample::Present { dev, ino, mtime_ns, size } => format!("present {dev} {ino} {mtime_ns} {size}"),
            Sample::Missing => MISSING.into(),
        }
    }
}

/// The helper, run as `tarmac __wait-changed-stat PATH`: one line for each
/// sample at the poll cadence, until a stat error, or until a write fails
/// because `wait` has gone.
pub fn stat_helper(args: &[String]) -> i32 {
    let [raw] = args else { return 2 };
    let started = Instant::now();
    let mut out = io::stdout().lock();
    let path = match std::path::absolute(raw) {
        Ok(path) => path,
        Err(e) => {
            let _ = writeln!(out, "{STAT_ERROR}cannot stat {raw}: {e}");
            return 0;
        }
    };
    loop {
        match sample(&path) {
            Ok(s) => {
                if writeln!(out, "{}", s.line()).and_then(|()| out.flush()).is_err() {
                    return 0;
                }
            }
            Err(e) => {
                let _ = writeln!(out, "{STAT_ERROR}cannot stat {}: {e}", path.display());
                return 0;
            }
        }
        std::thread::sleep(poll_interval(started.elapsed()));
    }
}

/// Starts the helper and hands its lines over a channel, so that `wait` can
/// read them with a deadline. The reader thread blocks on a pipe, which does
/// not keep the process from ending.
fn spawn_helper(cmd: &mut Command) -> io::Result<(Child, Receiver<String>)> {
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let stdout = child.stdout.take().expect("piped stdout");
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            if line.map_or(true, |line| tx.send(line).is_err()) {
                return;
            }
        }
    });
    Ok((child, rx))
}

/// Only changes after the start count: the first sample is the base.
fn watch(lines: &Receiver<String>, settle: Option<Duration>, deadline: Option<Instant>) -> Outcome {
    let mut last: Option<String> = None;
    let mut changed_at = None;
    loop {
        let now = Instant::now();
        if settled(changed_at, settle, now) {
            return Outcome::Done(Some(json!({ "deleted": last.as_deref() == Some(MISSING) })));
        }
        if deadline.is_some_and(|d| now >= d) {
            return Outcome::TimedOut;
        }
        let quiet_at = changed_at.zip(settle).map(|(at, settle)| at + settle);
        let next = match deadline.into_iter().chain(quiet_at).min() {
            Some(until) => lines.recv_timeout(until.saturating_duration_since(now)),
            None => lines.recv().map_err(|_| RecvTimeoutError::Disconnected),
        };
        match next {
            Ok(line) => {
                if let Some(why) = line.strip_prefix(STAT_ERROR) {
                    return Outcome::Failed(why.to_owned());
                }
                if last.as_ref().is_some_and(|l| *l != line) {
                    changed_at = Some(Instant::now());
                }
                last = Some(line);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return Outcome::Failed("the stat helper of wait --changed ended".into()),
        }
    }
}

/// The stat runs in `helper`, a process of its own (#361): on a volume that
/// does not answer, a stat blocks uninterruptibly for minutes, and a process
/// with a thread stuck there may not be able to exit. So this process gets no
/// path at all, not even to make it absolute, since a relative one reads the
/// cwd.
pub(super) fn changed(mut helper: Command, settle: Option<Duration>, deadline: Option<Instant>) -> Outcome {
    let (mut child, lines) = match spawn_helper(&mut helper) {
        Ok(started) => started,
        Err(e) => return Outcome::Failed(format!("cannot start the stat helper of wait --changed: {e}")),
    };
    let outcome = watch(&lines, settle, deadline);
    // Never waited for: a helper stuck in the kernel would hold this process
    // with it. It is left behind, and ends when its stat returns.
    let _ = child.kill();
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    // S27
    #[test]
    fn the_poll_is_fast_for_2_s_then_slow() {
        let ms = Duration::from_millis;
        assert_eq!(poll_interval(ms(0)), ms(100));
        assert_eq!(poll_interval(ms(1999)), ms(100));
        assert_eq!(poll_interval(ms(2000)), ms(250));
        assert_eq!(poll_interval(ms(60_000)), ms(250));
    }

    // S27
    #[test]
    fn the_wait_settles_only_after_a_quiet_settle_since_the_last_change() {
        let start = Instant::now();
        let at = |ms| start + Duration::from_millis(ms);
        let settle = Some(Duration::from_millis(500));

        assert!(!settled(None, None, at(10_000)));
        assert!(settled(Some(at(100)), None, at(100)));
        assert!(!settled(Some(at(100)), settle, at(599)));
        assert!(settled(Some(at(100)), settle, at(600)));
        assert!(!settled(Some(at(400)), settle, at(600)), "a later change starts the settle again");
    }

    fn line(s: Sample) -> String {
        s.line()
    }

    fn a() -> String {
        line(Sample::Present { dev: 1, ino: 2, mtime_ns: -3, size: 4 })
    }

    fn b() -> String {
        line(Sample::Present { dev: 1, ino: 2, mtime_ns: 5, size: 4 })
    }

    const DENIED: &str = "error cannot stat /x: denied";

    /// A source that gives `lines` and then stays open, as a helper that
    /// says no more.
    fn told(lines: Vec<String>) -> Receiver<String> {
        let (tx, rx) = mpsc::channel();
        for l in lines {
            tx.send(l).unwrap();
        }
        std::mem::forget(tx);
        rx
    }

    /// One child spawned at a time: on macOS a child spawned while a sibling's
    /// pipe is not yet close-on-exec keeps it open (#190).
    fn spawning() -> std::sync::MutexGuard<'static, ()> {
        static SPAWN: std::sync::Mutex<()> = std::sync::Mutex::new(());
        SPAWN.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn helper(cmd: &mut Command) -> (Child, Receiver<String>) {
        let _spawning = spawning();
        spawn_helper(cmd).unwrap()
    }

    fn within(ms: u64) -> Option<Instant> {
        Some(Instant::now() + Duration::from_millis(ms))
    }

    // S27
    #[test]
    fn a_sample_line_differs_in_any_of_its_facts() {
        let base = a();
        for other in [
            Sample::Present { dev: 9, ino: 2, mtime_ns: -3, size: 4 },
            Sample::Present { dev: 1, ino: 9, mtime_ns: -3, size: 4 },
            Sample::Present { dev: 1, ino: 2, mtime_ns: 9, size: 4 },
            Sample::Present { dev: 1, ino: 2, mtime_ns: -3, size: 9 },
            Sample::Missing,
        ] {
            assert_ne!(base, line(other));
        }
        assert_eq!(line(Sample::Missing), MISSING);
    }

    #[test]
    fn the_first_sample_is_the_base_and_a_different_one_ends_the_wait() {
        assert_eq!(watch(&told(vec![a(), a(), b()]), None, within(2000)), Outcome::Done(Some(json!({ "deleted": false }))));
        assert_eq!(watch(&told(vec![a(), line(Sample::Missing)]), None, within(2000)), Outcome::Done(Some(json!({ "deleted": true }))));
    }

    #[test]
    fn the_same_sample_again_is_no_change_and_the_deadline_is_124() {
        assert_eq!(watch(&told(vec![a(), a(), a()]), None, within(300)), Outcome::TimedOut);
    }

    #[test]
    fn no_sample_at_all_is_124_at_the_deadline() {
        let started = Instant::now();
        assert_eq!(watch(&told(vec![]), None, within(300)), Outcome::TimedOut);
        let took = started.elapsed();
        assert!(took >= Duration::from_millis(300) && took < Duration::from_millis(800), "{took:?}");
    }

    #[test]
    fn settle_waits_for_quiet_after_the_last_change() {
        let started = Instant::now();
        let out = watch(&told(vec![a(), b()]), Some(Duration::from_millis(300)), within(3000));
        assert_eq!(out, Outcome::Done(Some(json!({ "deleted": false }))));
        assert!(started.elapsed() >= Duration::from_millis(300), "{:?}", started.elapsed());
    }

    #[test]
    fn a_timeout_while_it_settles_is_124() {
        assert_eq!(watch(&told(vec![a(), b()]), Some(Duration::from_millis(1000)), within(300)), Outcome::TimedOut);
    }

    #[test]
    fn a_stat_error_from_the_helper_exits_1_with_its_words() {
        let out = watch(&told(vec![a(), DENIED.into()]), None, within(2000));
        assert_eq!(out, Outcome::Failed("cannot stat /x: denied".into()));
    }

    #[test]
    fn a_helper_that_goes_away_is_a_failure() {
        let (tx, rx) = mpsc::channel();
        tx.send(a()).unwrap();
        drop(tx);
        assert!(matches!(watch(&rx, None, within(2000)), Outcome::Failed(why) if why.contains("helper")));
    }

    #[test]
    fn a_helper_process_that_never_writes_is_124_at_the_deadline() {
        let (mut child, lines) = helper(Command::new("sleep").arg("30"));
        let started = Instant::now();
        let out = watch(&lines, None, within(300));
        let took = started.elapsed();
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(out, Outcome::TimedOut);
        assert!(took < Duration::from_millis(800), "{took:?}");
    }

    #[test]
    fn the_lines_of_a_helper_process_reach_the_wait() {
        let script = format!("echo '{}'; echo '{}'", a(), b());
        let (mut child, lines) = helper(Command::new("sh").args(["-c", &script]));
        let got: Vec<String> = lines.iter().collect();
        let _ = child.wait();
        assert_eq!(got, vec![a(), b()]);
    }

    #[test]
    fn a_helper_process_that_dies_is_a_failure() {
        let (mut child, lines) = helper(Command::new("sh").args(["-c", "exit 3"]));
        let out = watch(&lines, None, within(2000));
        let _ = child.wait();
        assert!(matches!(out, Outcome::Failed(why) if why.contains("helper")));
    }

    fn sh(script: &str) -> Command {
        let mut cmd = Command::new("sh");
        cmd.args(["-c", script]);
        cmd
    }

    #[test]
    fn changed_needs_no_path_only_the_helper_s_lines() {
        let _spawning = spawning();
        let out = changed(sh("echo a; sleep 0.2; echo b; exec sleep 30"), None, within(3000));
        assert_eq!(out, Outcome::Done(Some(json!({ "deleted": false }))));
    }

    #[test]
    fn a_helper_that_never_answers_is_killed_at_the_deadline() {
        let pid_file = std::env::temp_dir().join(format!("tarmac-wait-helper-{}.pid", std::process::id()));
        let _spawning = spawning();
        let started = Instant::now();
        let out = changed(sh(&format!("echo $$ > {}; exec sleep 30", pid_file.display())), None, within(500));
        let took = started.elapsed();
        assert_eq!(out, Outcome::TimedOut);
        assert!(took < Duration::from_millis(1000), "{took:?}");

        let pid = std::fs::read_to_string(&pid_file).unwrap().trim().to_owned();
        let _ = std::fs::remove_file(&pid_file);
        let state = || {
            let ps = Command::new("ps").args(["-o", "stat=", "-p", &pid]).output().unwrap();
            String::from_utf8_lossy(&ps.stdout).trim().to_owned()
        };
        let until = Instant::now() + Duration::from_millis(500);
        while !(state().is_empty() || state().starts_with('Z')) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        let left = state();
        assert!(left.is_empty() || left.starts_with('Z'), "the helper is still {left:?}");
    }
}
