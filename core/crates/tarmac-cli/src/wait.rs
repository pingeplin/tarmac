//! `tarmac wait`: block until one fact (spec 2611.0012). `--exit`, `--bell`
//! and `--report` subscribe to the daemon; `--changed` stats the path in a
//! helper process and never connects, so it adds no watch. Exit 124 is a
//! timeout.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tarmac_protocol::Msg;

use crate::events::{self, Stop};

const USAGE: &str =
    "usage: tarmac wait --exit ID | --bell ID | --report blocked|done --term ID | --changed PATH [--settle MS] [--timeout MS]";
const TIMED_OUT: i32 = 124;
/// The argument that runs `stat_helper`: internal, so not in `tarmac help`.
pub const STAT_HELPER: &str = "__wait-changed-stat";

#[derive(Debug, PartialEq)]
enum Mode {
    Exit(String),
    Bell(String),
    Report { kind: String, term_id: String },
    Changed { path: String, settle: Option<Duration> },
}

impl Mode {
    /// The kinds a daemon wait subscribes to, and its terminal; `None` for
    /// `--changed`. A bell or report wait takes the exit too.
    fn daemon(&self) -> Option<(&'static [&'static str], &str)> {
        match self {
            Mode::Exit(id) => Some((&["exit"], id)),
            Mode::Bell(id) => Some((&["bell", "exit"], id)),
            Mode::Report { term_id, .. } => Some((&["report", "exit"], term_id)),
            Mode::Changed { .. } => None,
        }
    }
}

pub fn run(args: &[String]) -> i32 {
    let started = Instant::now();
    let Some((mode, timeout)) = parse(args) else {
        eprintln!("tarmac: {USAGE}");
        return 2;
    };
    // A sum past what `Instant` holds is no deadline at all.
    let deadline = timeout.and_then(|t| started.checked_add(t));
    let outcome = match &mode {
        Mode::Changed { path, settle } => changed(path, *settle, deadline),
        mode => from_daemon(mode, deadline),
    };
    match outcome {
        Outcome::Done(line) => {
            if let Some(line) = line {
                let _ = writeln!(io::stdout(), "{line}");
            }
            0
        }
        Outcome::Failed(why) => {
            eprintln!("tarmac: {why}");
            1
        }
        Outcome::TimedOut => TIMED_OUT,
    }
}

#[derive(Debug, PartialEq)]
enum Outcome {
    Done(Option<Value>),
    Failed(String),
    TimedOut,
}

fn from_daemon(mode: &Mode, deadline: Option<Instant>) -> Outcome {
    let Some((kinds, term_id)) = mode.daemon() else { return Outcome::Failed("--changed does not talk to the daemon".into()) };
    let kinds = kinds.iter().map(|k| k.to_string()).collect();
    let (mut stream, snapshot) = match events::subscribe(Some(kinds), Some(term_id.to_owned()), deadline) {
        Ok(opened) => opened,
        Err(Stop::Late) => {
            eprintln!("tarmac: wait: timed out before the daemon answered");
            return Outcome::TimedOut;
        }
        Err(Stop::Fail(why)) => return Outcome::Failed(why),
    };
    if let Some(outcome) = snapshot.iter().find_map(|msg| verdict(mode, msg)) {
        return outcome;
    }
    loop {
        match events::next(&mut stream, deadline) {
            Ok(msg) => {
                if let Some(outcome) = verdict(mode, &msg) {
                    return outcome;
                }
            }
            Err(Stop::Late) => return Outcome::TimedOut,
            Err(Stop::Fail(why)) => return Outcome::Failed(why),
        }
    }
}

/// What `msg` means for the wait, `None` when it goes on. An exit ends a
/// wait for a bell or a report that can no longer come.
fn verdict(mode: &Mode, msg: &Msg) -> Option<Outcome> {
    let (_, id) = mode.daemon()?;
    match (mode, msg) {
        (_, Msg::Exit { term_id, .. } | Msg::Bell { term_id, .. } | Msg::TermReport { term_id, .. }) if term_id != id => None,
        (Mode::Exit(_), Msg::Exit { code: Some(code), .. }) => Some(Outcome::Done(Some(json!({ "code": code })))),
        (Mode::Exit(_), Msg::Exit { code: None, .. }) => Some(Outcome::Done(Some(json!({ "signal": true })))),
        (_, Msg::Exit { .. }) => Some(Outcome::Failed(format!("terminal {id} exited"))),
        (Mode::Bell(_), Msg::Bell { .. }) => Some(Outcome::Done(None)),
        (Mode::Report { kind: want, .. }, Msg::TermReport { kind: Some(got), .. }) if got == want => {
            Some(Outcome::Done(serde_json::to_value(events::Report::of(msg)?).ok()))
        }
        _ => None,
    }
}

/// The mode and the `--timeout`; `None` is a usage error.
fn parse(args: &[String]) -> Option<(Mode, Option<Duration>)> {
    const FLAGS: [&str; 7] = ["exit", "bell", "report", "changed", "term", "settle", "timeout"];
    let mut flags: HashMap<&str, String> = HashMap::new();
    let mut rest = args.iter();
    while let Some(flag) = rest.next() {
        let name = flag.strip_prefix("--").filter(|n| FLAGS.contains(n))?;
        if flags.insert(name, rest.next()?.clone()).is_some() {
            return None;
        }
    }
    let mut take = |name: &str| flags.remove(name);
    let millis = |v: Option<String>| -> Option<Option<Duration>> {
        match v {
            None => Some(None),
            Some(v) => v.parse::<u64>().ok().filter(|ms| *ms >= 1).map(|ms| Some(Duration::from_millis(ms))),
        }
    };
    let (exit, bell, report, changed) = (take("exit"), take("bell"), take("report"), take("changed"));
    let (term, settle, timeout) = (take("term"), millis(take("settle"))?, millis(take("timeout"))?);
    let mode = match (exit, bell, report, changed) {
        (Some(id), None, None, None) => Mode::Exit(id),
        (None, Some(id), None, None) => Mode::Bell(id),
        (None, None, Some(kind), None) if kind == "blocked" || kind == "done" => Mode::Report { kind, term_id: term.clone()? },
        (None, None, None, Some(path)) => Mode::Changed { path, settle },
        _ => return None,
    };
    let term_ok = term.is_none() || matches!(mode, Mode::Report { .. });
    let settle_ok = settle.is_none() || matches!(mode, Mode::Changed { .. });
    (term_ok && settle_ok).then_some((mode, timeout))
}

/// One stat of the path: its identity, mtime and size, or that it is not
/// there. A change of `ino` or `dev` is a file replaced by a rename.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
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
    let [path] = args else { return 2 };
    let started = Instant::now();
    let mut out = io::stdout().lock();
    loop {
        match sample(Path::new(path)) {
            Ok(s) => {
                if writeln!(out, "{}", s.line()).and_then(|()| out.flush()).is_err() {
                    return 0;
                }
            }
            Err(e) => {
                let _ = writeln!(out, "{STAT_ERROR}cannot stat {path}: {e}");
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

/// The stat runs in a helper process (#361): on a volume that does not
/// answer, a stat blocks uninterruptibly for minutes, and a process with a
/// thread stuck there may not be able to exit. So this process never touches
/// the path, and on its way out it leaves a stuck helper behind.
fn changed(raw: &str, settle: Option<Duration>, deadline: Option<Instant>) -> Outcome {
    let path = match std::path::absolute(raw) {
        Ok(path) => path,
        Err(e) => return Outcome::Failed(format!("cannot stat {raw}: {e}")),
    };
    let helper = std::env::current_exe().and_then(|exe| spawn_helper(Command::new(exe).arg(STAT_HELPER).arg(&path)));
    let (mut child, samples) = match helper {
        Ok(started) => started,
        Err(e) => return Outcome::Failed(format!("cannot start the stat helper of wait --changed: {e}")),
    };
    let outcome = watch(&samples, settle, deadline);
    let _ = child.kill();
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

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
    fn a_sample_differs_in_any_of_its_facts() {
        let base = Sample::Present { dev: 1, ino: 2, mtime_ns: 3, size: 4 };
        for other in [
            Sample::Present { dev: 9, ino: 2, mtime_ns: 3, size: 4 },
            Sample::Present { dev: 1, ino: 9, mtime_ns: 3, size: 4 },
            Sample::Present { dev: 1, ino: 2, mtime_ns: 9, size: 4 },
            Sample::Present { dev: 1, ino: 2, mtime_ns: 3, size: 9 },
            Sample::Missing,
        ] {
            assert_ne!(base, other);
        }
        assert_eq!(base, Sample::Present { dev: 1, ino: 2, mtime_ns: 3, size: 4 });
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

    /// `spawn_helper`, one child at a time: on macOS a child spawned while a
    /// sibling's pipe is not yet close-on-exec keeps it open (#190).
    fn helper(cmd: &mut Command) -> (Child, Receiver<String>) {
        static SPAWN: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _spawning = SPAWN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        spawn_helper(cmd).unwrap()
    }

    fn within(ms: u64) -> Option<Instant> {
        Some(Instant::now() + Duration::from_millis(ms))
    }

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

    #[test]
    fn each_mode_is_parsed() {
        let t = Some(Duration::from_millis(300));
        assert_eq!(parse(&args(&["--exit", "t1"])), Some((Mode::Exit("t1".into()), None)));
        assert_eq!(parse(&args(&["--bell", "t1", "--timeout", "300"])), Some((Mode::Bell("t1".into()), t)));
        assert_eq!(
            parse(&args(&["--term", "t1", "--report", "done"])),
            Some((Mode::Report { kind: "done".into(), term_id: "t1".into() }, None))
        );
        assert_eq!(
            parse(&args(&["--changed", "a.md", "--settle", "500"])),
            Some((Mode::Changed { path: "a.md".into(), settle: Some(Duration::from_millis(500)) }, None))
        );
    }

    #[test]
    fn a_bad_set_of_flags_is_a_usage_error() {
        for bad in [
            &[][..],
            &["--exit"],
            &["--exit", "t1", "--bell", "t1"],
            &["--report", "later", "--term", "t1"],
            &["--report", "done"],
            &["--exit", "t1", "--term", "t1"],
            &["--exit", "t1", "--settle", "5"],
            &["--exit", "t1", "--timeout", "0"],
            &["--exit", "t1", "--timeout", "abc"],
            &["--exit", "t1", "--timeout", "-1"],
            &["--changed"],
            &["--changed", "a", "--settle", "0"],
            &["--exit", "t1", "--exit", "t2"],
            &["--exit", "t1", "x"],
        ] {
            assert_eq!(parse(&args(bad)), None, "{bad:?}");
        }
    }
}
