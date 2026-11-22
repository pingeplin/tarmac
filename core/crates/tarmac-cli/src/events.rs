//! `tarmac events`: the daemon's exits, bells, doc changes and reports as
//! JSON lines (spec 2611.0012), and the subscribe exchange that `tarmac wait`
//! shares. The cli checks each frame's kind and terminal itself: it does not
//! trust the daemon's filter alone.

use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tarmac_protocol::{self as proto, EventKind, Msg, frame};

use crate::daemon::NoHandshake;

const USAGE: &str = "usage: tarmac events [--term ID] [--kind exit,bell,changed,report]";
const LAGGED: &str = "the daemon dropped this stream: it fell behind (lagged)";

pub fn run(args: &[String]) -> i32 {
    let Some(want) = parse(args) else {
        eprintln!("tarmac: {USAGE}");
        return 2;
    };
    let kinds = want.kinds.as_ref().map(|k| k.iter().map(|k| k.name().to_string()).collect());
    let (mut stream, snapshot) = match subscribe(kinds, want.term_id.clone(), None) {
        Ok(opened) => opened,
        Err(stop) => return stopped(stop),
    };
    let mut out = io::stdout().lock();
    for msg in snapshot.iter().filter(|m| want.admits(m)) {
        if print(&mut out, msg, true).is_err() {
            return 0;
        }
    }
    loop {
        match next(&mut stream, None) {
            Ok(msg) if want.admits(&msg) => {
                // A closed stdout is the reader's end, not a failure (D16).
                if print(&mut out, &msg, false).is_err() {
                    return 0;
                }
            }
            Ok(_) => {}
            Err(stop) => return stopped(stop),
        }
    }
}

fn print(out: &mut impl Write, msg: &Msg, snapshot: bool) -> io::Result<()> {
    let Some(line) = Line::of(msg, snapshot, now_ms()) else { return Ok(()) };
    writeln!(out, "{}", serde_json::to_string(&line).map_err(io::Error::other)?)?;
    out.flush()
}

fn stopped(stop: Stop) -> i32 {
    if let Stop::Fail(why) = stop {
        eprintln!("tarmac: {why}");
    }
    1
}

#[expect(clippy::cast_possible_truncation, reason = "predates the lint; decided in #470")]
fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// What `events` asks for: the `--kind`s in their order (`None` is all) and
/// the `--term`.
#[derive(Debug, PartialEq)]
struct Want {
    kinds: Option<Vec<EventKind>>,
    term_id: Option<String>,
}

impl Want {
    fn admits(&self, msg: &Msg) -> bool {
        EventKind::admits(self.kinds.as_deref().unwrap_or(&EventKind::ALL), self.term_id.as_deref(), msg)
    }
}

/// `None` is a usage error: an unknown or empty kind, a flag twice or with no
/// value, a stray argument, or `--term` with `changed` named, since a
/// `file_event` has no terminal.
fn parse(args: &[String]) -> Option<Want> {
    let (mut kinds, mut term_id) = (None, None);
    let mut rest = args.iter();
    while let Some(flag) = rest.next() {
        let slot = match flag.as_str() {
            "--kind" => &mut kinds,
            "--term" => &mut term_id,
            _ => return None,
        };
        if slot.replace(rest.next()?.clone()).is_some() {
            return None;
        }
    }
    let kinds: Option<Vec<EventKind>> = match kinds {
        Some(names) => Some(names.split(',').map(EventKind::named).collect::<Option<_>>()?),
        None => None,
    };
    if term_id.is_some() && kinds.as_ref().is_some_and(|k| k.contains(&EventKind::Changed)) {
        return None;
    }
    Some(Want { kinds, term_id })
}

/// One JSON line. Its keys are written in field order.
#[derive(Serialize)]
struct Line<'a> {
    event: &'static str,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    snapshot: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    term: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    board: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<i64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    signal: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    mtime_ms: Option<u64>,
    #[serde(flatten)]
    report: Option<Report<'a>>,
    received_ms: u64,
}

impl<'a> Line<'a> {
    /// The line of an event frame, `None` for any other. `received_ms` is the
    /// cli's clock when it read the frame; a snapshot frame is marked.
    fn of(msg: &'a Msg, snapshot: bool, received_ms: u64) -> Option<Line<'a>> {
        let (kind, term) = EventKind::of(msg)?;
        let mut line = Line {
            event: kind.name(),
            snapshot,
            term,
            board: None,
            code: None,
            signal: false,
            path: None,
            mtime_ms: None,
            report: Report::of(msg),
            received_ms,
        };
        match msg {
            Msg::Exit { code, board_id, .. } => {
                (line.board, line.code, line.signal) = (board_id.as_deref(), *code, code.is_none());
            }
            Msg::Bell { board_id, .. } | Msg::TermReport { board_id, .. } => line.board = board_id.as_deref(),
            Msg::FileEvent { path, mtime_ms } => (line.path, line.mtime_ms) = (Some(path.as_str()), Some(*mtime_ms)),
            _ => {}
        }
        Some(line)
    }
}

/// A report's own keys, as `wait --report` prints them.
#[derive(Serialize)]
pub(crate) struct Report<'a> {
    kind: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    proc: Option<&'a str>,
    at_ms: Option<u64>,
    read: bool,
}

impl<'a> Report<'a> {
    /// `None` for a frame with no report.
    pub(crate) fn of(msg: &'a Msg) -> Option<Report<'a>> {
        let Msg::TermReport { kind: Some(kind), text, at_ms, proc, read, .. } = msg else { return None };
        Some(Report { kind, text: text.as_deref(), proc: proc.as_deref(), at_ms: *at_ms, read: *read })
    }
}

/// Why a stream ended: a line for stderr with exit 1, or the `--timeout`
/// deadline.
pub(crate) enum Stop {
    Fail(String),
    Late,
}

/// Connects, sends `subscribe` and reads to `ack`: the stream and the
/// snapshot frames before it. Each wait ends at the earlier of 5 s and
/// `deadline`; running out is `Late` when `deadline` is that limit.
pub(crate) fn subscribe(
    kinds: Option<Vec<String>>,
    term_id: Option<String>,
    deadline: Option<Instant>,
) -> Result<(UnixStream, Vec<Msg>), Stop> {
    let five = Instant::now() + crate::daemon::DAEMON_WAIT;
    let until = deadline.map_or(five, |d| d.min(five));
    let late = deadline.is_some_and(|d| d <= five);
    let no_answer = crate::daemon::no_answer_older();
    let stop = |e: io::Error| match crate::daemon::is_timeout(&e) {
        true if late => Stop::Late,
        true => Stop::Fail(no_answer.clone()),
        false => Stop::Fail(crate::daemon::lost(e)),
    };
    let mut stream = crate::daemon::connect_until(until).map_err(|e| match e {
        NoHandshake::TimedOut if late => Stop::Late,
        e => Stop::Fail(e.worded(&no_answer)),
    })?;
    let payload =
        proto::encode(&Msg::Subscribe { kinds, term_id }).map_err(|e| Stop::Fail(format!("encode failed: {e}")))?;
    crate::daemon::time_out_at(&stream, until).and_then(|()| frame::write_sync(&mut stream, &payload)).map_err(stop)?;
    let mut snapshot = Vec::new();
    loop {
        match decoded(&read(&mut stream, Some(until)).map_err(stop)?)? {
            Msg::Ack => return Ok((stream, snapshot)),
            Msg::Err { msg } => return Err(Stop::Fail(msg)),
            msg => snapshot.push(msg),
        }
    }
}

/// The next frame after `ack`. With a `deadline`, running out is `Late`.
pub(crate) fn next(stream: &mut UnixStream, deadline: Option<Instant>) -> Result<Msg, Stop> {
    let payload = read(stream, deadline).map_err(|e| match crate::daemon::is_timeout(&e) && deadline.is_some() {
        true => Stop::Late,
        false => Stop::Fail(crate::daemon::lost(e)),
    })?;
    match decoded(&payload)? {
        Msg::Err { msg } if msg == "lagged" => Err(Stop::Fail(LAGGED.into())),
        Msg::Err { msg } => Err(Stop::Fail(msg)),
        msg => Ok(msg),
    }
}

/// One frame, read by `until` (with no limit for `None`). macOS refuses a
/// timeout on a socket the peer has closed; that refusal is let pass, and
/// the read reports the close.
fn read(stream: &mut UnixStream, until: Option<Instant>) -> io::Result<Vec<u8>> {
    let set = match until {
        Some(until) => crate::daemon::time_out_at(stream, until),
        None => stream.set_read_timeout(None),
    };
    match set {
        Err(e) if crate::daemon::is_timeout(&e) => Err(e),
        _ => frame::read_sync(stream),
    }
}

fn decoded(payload: &[u8]) -> Result<Msg, Stop> {
    proto::decode(payload).map_err(|e| Stop::Fail(format!("bad frame from daemon: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixtures::args;

    fn text(msg: &Msg, snapshot: bool) -> String {
        serde_json::to_string(&Line::of(msg, snapshot, 9).unwrap()).unwrap()
    }

    fn report(kind: Option<&str>, text: Option<&str>, proc: Option<&str>, board_id: Option<&str>) -> Msg {
        Msg::TermReport {
            term_id: "t1".into(),
            kind: kind.map(str::to_string),
            text: text.map(str::to_string),
            at_ms: kind.map(|_| 7),
            proc: proc.map(str::to_string),
            read: true,
            board_id: board_id.map(str::to_string),
            cwd: Some("/w".into()),
        }
    }

    #[test]
    fn each_event_frame_has_its_line_with_keys_in_order() {
        let cases = [
            (
                Msg::Exit { term_id: "t1".into(), code: Some(3), board_id: None },
                r#"{"event":"exit","term":"t1","code":3,"received_ms":9}"#,
            ),
            (
                Msg::Exit { term_id: "t1".into(), code: None, board_id: Some("b1".into()) },
                r#"{"event":"exit","term":"t1","board":"b1","signal":true,"received_ms":9}"#,
            ),
            (
                Msg::Bell { term_id: "t1".into(), board_id: Some("b1".into()) },
                r#"{"event":"bell","term":"t1","board":"b1","received_ms":9}"#,
            ),
            (
                Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 },
                r#"{"event":"changed","path":"/a.md","mtime_ms":5,"received_ms":9}"#,
            ),
            (
                report(Some("done"), Some("ok"), Some("claude"), Some("b1")),
                r#"{"event":"report","term":"t1","board":"b1","kind":"done","text":"ok","proc":"claude","at_ms":7,"read":true,"received_ms":9}"#,
            ),
            (
                report(Some("blocked"), None, None, None),
                r#"{"event":"report","term":"t1","kind":"blocked","at_ms":7,"read":true,"received_ms":9}"#,
            ),
            (report(None, None, None, None), r#"{"event":"report","term":"t1","received_ms":9}"#),
        ];
        for (msg, want) in cases {
            assert_eq!(text(&msg, false), want, "{msg:?}");
        }
    }

    #[test]
    fn a_report_with_no_kind_names_the_board_its_frame_carries() {
        assert_eq!(
            text(&report(None, None, None, Some("b1")), false),
            r#"{"event":"report","term":"t1","board":"b1","received_ms":9}"#
        );
    }

    #[test]
    fn a_snapshot_line_is_marked_after_its_event() {
        let msg = Msg::Bell { term_id: "t1".into(), board_id: None };
        assert_eq!(text(&msg, true), r#"{"event":"bell","snapshot":true,"term":"t1","received_ms":9}"#);
    }

    #[test]
    fn a_frame_that_is_not_an_event_has_no_line() {
        assert!(Line::of(&Msg::Output { term_id: "t1".into(), bytes: vec![] }, false, 9).is_none());
        assert!(Line::of(&Msg::Ack, false, 9).is_none());
    }

    #[test]
    fn the_flags_are_parsed_and_kinds_keep_their_order() {
        let want = |kinds: Option<Vec<EventKind>>, term_id: Option<&str>| {
            Some(Want { kinds, term_id: term_id.map(str::to_string) })
        };
        assert_eq!(parse(&args(&[])), want(None, None));
        assert_eq!(
            parse(&args(&["--kind", "report,exit", "--term", "t1"])),
            want(Some(vec![EventKind::Report, EventKind::Exit]), Some("t1"))
        );
        assert_eq!(parse(&args(&["--term", "t1"])), want(None, Some("t1")));
    }

    #[test]
    fn a_bad_flag_is_a_usage_error() {
        for bad in [
            &["--kind", "later"][..],
            &["--kind", ""],
            &["--kind", "bell,"],
            &["--term", "t1", "--kind", "changed"],
            &["x"],
            &["--term"],
            &["--kind"],
            &["--term", "a", "--term", "b"],
            &["--kind", "bell", "--kind", "exit"],
            &["--term", "t1", "--kind", "bell,changed"],
        ] {
            assert_eq!(parse(&args(bad)), None, "{bad:?}");
        }
    }
}
