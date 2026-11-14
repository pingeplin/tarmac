//! `tarmac wait`: block until one fact (spec 2611.0012). `--exit`, `--bell`
//! and `--report` subscribe to the daemon; `--changed` stats the path in the
//! cli and never connects, so it adds no watch. Exit 124 is a timeout.

use std::collections::HashMap;
use std::io::{self, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tarmac_protocol::Msg;

use crate::events::{self, Stop};

const USAGE: &str =
    "usage: tarmac wait --exit ID | --bell ID | --report blocked|done --term ID | --changed PATH [--settle MS] [--timeout MS]";
const TIMED_OUT: i32 = 124;

#[derive(Debug, PartialEq)]
enum Mode {
    Exit(String),
    Bell(String),
    Report { kind: String, term_id: String },
    Changed { path: String, settle: Option<Duration> },
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
        Mode::Exit(id) => from_daemon(&mode, &["exit"], id, deadline),
        Mode::Bell(id) => from_daemon(&mode, &["bell", "exit"], id, deadline),
        Mode::Report { term_id, .. } => from_daemon(&mode, &["report", "exit"], term_id, deadline),
        Mode::Changed { path, settle } => changed(path, *settle, started, deadline),
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

enum Outcome {
    Done(Option<Value>),
    Failed(String),
    TimedOut,
}

fn from_daemon(mode: &Mode, kinds: &[&str], term_id: &str, deadline: Option<Instant>) -> Outcome {
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
    let (kind, term) = events::kind_of(msg)?;
    let (Mode::Exit(id) | Mode::Bell(id) | Mode::Report { term_id: id, .. }) = mode else { return None };
    if term != Some(id.as_str()) {
        return None;
    }
    match (mode, msg) {
        (Mode::Exit(_), Msg::Exit { code: Some(code), .. }) => Some(Outcome::Done(Some(json!({ "code": code })))),
        (Mode::Exit(_), Msg::Exit { code: None, .. }) => Some(Outcome::Done(Some(json!({ "signal": true })))),
        (_, Msg::Exit { .. }) => Some(Outcome::Failed(format!("terminal {id} exited"))),
        (Mode::Bell(_), _) if kind == "bell" => Some(Outcome::Done(None)),
        (Mode::Report { kind: want, .. }, Msg::TermReport { kind: Some(got), .. }) if got == want => {
            events::report(msg).map(|m| Outcome::Done(Some(Value::Object(m))))
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

/// Only changes after the start count: the first sample is the base.
fn changed(raw: &str, settle: Option<Duration>, started: Instant, deadline: Option<Instant>) -> Outcome {
    let path: PathBuf = match std::path::absolute(raw) {
        Ok(path) => path,
        Err(e) => return Outcome::Failed(format!("cannot stat {raw}: {e}")),
    };
    let stat = |path: &Path| sample(path).map_err(|e| Outcome::Failed(format!("cannot stat {}: {e}", path.display())));
    let mut last = match stat(&path) {
        Ok(s) => s,
        Err(failed) => return failed,
    };
    let mut changed_at = None;
    loop {
        let now = Instant::now();
        if settled(changed_at, settle, now) {
            return Outcome::Done(Some(json!({ "deleted": last == Sample::Missing })));
        }
        let left = deadline.map(|d| d.saturating_duration_since(now));
        if left.is_some_and(|l| l.is_zero()) {
            return Outcome::TimedOut;
        }
        let interval = poll_interval(now.duration_since(started));
        std::thread::sleep(left.map_or(interval, |l| l.min(interval)));
        match stat(&path) {
            Ok(now) if now != last => {
                last = now;
                changed_at = Some(Instant::now());
            }
            Ok(_) => {}
            Err(failed) => return failed,
        }
    }
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
