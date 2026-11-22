//! `tarmac wait`: block until one fact (spec 2611.0012). `--exit`, `--bell`
//! and `--report` subscribe to the daemon; `--changed` stats the path in a
//! helper process and never connects, so it adds no watch. Exit 124 is a
//! timeout.

use std::collections::HashMap;
use std::io::{self, Write};
use std::process::Command;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tarmac_protocol::{Msg, ReportKind};

use crate::events::{self, Stop};

mod changed;

use changed::changed;
pub(crate) use changed::{STAT_HELPER, stat_helper};

const USAGE: &str = "usage: tarmac wait --exit ID | --bell ID | --report blocked|done --term ID | --changed PATH [--settle MS] [--timeout MS]";
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
        Mode::Changed { path, settle } => match std::env::current_exe() {
            Ok(exe) => {
                let mut helper = Command::new(exe);
                helper.arg(STAT_HELPER).arg(path);
                changed(helper, *settle, deadline)
            }
            Err(e) => Outcome::Failed(format!("cannot start the stat helper of wait --changed: {e}")),
        },
        Mode::Exit(id) => from_daemon(&mode, &["exit"], id, deadline),
        Mode::Bell(id) => from_daemon(&mode, &["bell", "exit"], id, deadline),
        Mode::Report { term_id, .. } => from_daemon(&mode, &["report", "exit"], term_id, deadline),
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

/// The wait on terminal `term_id` for `kinds`, which a bell or report wait
/// extends with the exit.
fn from_daemon(mode: &Mode, kinds: &[&str], term_id: &str, deadline: Option<Instant>) -> Outcome {
    let kinds = kinds.iter().map(ToString::to_string).collect();
    let (mut stream, snapshot) = match events::subscribe(Some(kinds), Some(term_id.to_owned()), deadline) {
        Ok(opened) => opened,
        Err(Stop::Late) => {
            eprintln!("tarmac: wait: timed out before the daemon answered");
            return Outcome::TimedOut;
        }
        Err(Stop::Fail(why)) => return Outcome::Failed(why),
    };
    if let Some(outcome) = snapshot.iter().find_map(|msg| verdict(mode, term_id, msg)) {
        return outcome;
    }
    loop {
        match events::next(&mut stream, deadline) {
            Ok(msg) => {
                if let Some(outcome) = verdict(mode, term_id, &msg) {
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
fn verdict(mode: &Mode, id: &str, msg: &Msg) -> Option<Outcome> {
    match (mode, msg) {
        (_, Msg::Exit { term_id, .. } | Msg::Bell { term_id, .. } | Msg::TermReport { term_id, .. })
            if term_id != id =>
        {
            None
        }
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
        (None, None, Some(kind), None) if ReportKind::named(&kind).is_some() => {
            Mode::Report { kind, term_id: term.clone()? }
        }
        (None, None, None, Some(path)) => Mode::Changed { path, settle },
        _ => return None,
    };
    let term_ok = term.is_none() || matches!(mode, Mode::Report { .. });
    let settle_ok = settle.is_none() || matches!(mode, Mode::Changed { .. });
    (term_ok && settle_ok).then_some((mode, timeout))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::args;

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
