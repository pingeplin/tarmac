//! `tarmac events`: the daemon's exits, bells, doc changes and reports as
//! JSON lines (spec 2611.0012), and the subscribe exchange that `tarmac wait`
//! shares. The cli checks each frame's kind and terminal itself: it does not
//! trust the daemon's filter alone.

use std::cell::Cell;
use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};
use tarmac_protocol::{self as proto, Msg, frame};

const USAGE: &str = "usage: tarmac events [--term ID] [--kind exit,bell,changed,report]";
const KINDS: [&str; 4] = ["exit", "bell", "changed", "report"];
const LAGGED: &str = "the daemon dropped this stream: it fell behind (lagged)";

pub fn run(args: &[String]) -> i32 {
    let Some((kinds, term_id)) = parse(args) else {
        eprintln!("tarmac: {USAGE}");
        return 2;
    };
    let wanted = |msg: &Msg| {
        kind_of(msg).is_some_and(|(kind, term)| {
            kinds.as_ref().is_none_or(|k| k.iter().any(|n| n == kind)) && term_id.as_deref().is_none_or(|want| term == Some(want))
        })
    };
    let (mut stream, snapshot) = match subscribe(kinds.clone(), term_id.clone(), None) {
        Ok(opened) => opened,
        Err(stop) => return stopped(stop),
    };
    let mut out = io::stdout().lock();
    for msg in snapshot.iter().filter(|m| wanted(m)) {
        if print(&mut out, msg, true).is_err() {
            return 0;
        }
    }
    loop {
        match next(&mut stream, None) {
            Ok(msg) if wanted(&msg) => {
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
    let Some(line) = line(msg, snapshot, now_ms()) else { return Ok(()) };
    writeln!(out, "{line}")?;
    out.flush()
}

fn stopped(stop: Stop) -> i32 {
    if let Stop::Fail(why) = stop {
        eprintln!("tarmac: {why}");
    }
    1
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

/// The filter: `--kind` as given, `--term`. `None` is a usage error: an
/// unknown or empty kind, a flag twice or with no value, a stray argument,
/// or `--term` with `changed` named, since a `file_event` has no terminal.
fn parse(args: &[String]) -> Option<(Option<Vec<String>>, Option<String>)> {
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
    let kinds: Option<Vec<String>> = kinds.map(|k| k.split(',').map(str::to_string).collect());
    if kinds.as_ref().is_some_and(|k| k.iter().any(|n| !KINDS.contains(&n.as_str()))) {
        return None;
    }
    if term_id.is_some() && kinds.as_ref().is_some_and(|k| k.iter().any(|n| n == "changed")) {
        return None;
    }
    Some((kinds, term_id))
}

/// The kind of an event frame, by its cli name, and its terminal.
pub(crate) fn kind_of(msg: &Msg) -> Option<(&'static str, Option<&str>)> {
    match msg {
        Msg::Exit { term_id, .. } => Some(("exit", Some(term_id))),
        Msg::Bell { term_id, .. } => Some(("bell", Some(term_id))),
        Msg::FileEvent { .. } => Some(("changed", None)),
        Msg::TermReport { term_id, .. } => Some(("report", Some(term_id))),
        _ => None,
    }
}

/// One JSON line for an event frame, `None` for any other. `received_ms` is
/// the cli's clock when it read the frame; a snapshot frame is marked.
fn line(msg: &Msg, snapshot: bool, received_ms: u64) -> Option<Value> {
    let (event, _) = kind_of(msg)?;
    let mut m = Map::new();
    m.insert("event".into(), json!(event));
    if snapshot {
        m.insert("snapshot".into(), json!(true));
    }
    let mut put = |key: &str, value: Option<Value>| {
        if let Some(value) = value {
            m.insert(key.into(), value);
        }
    };
    match msg {
        Msg::Exit { term_id, code, board_id } => {
            put("term", Some(json!(term_id)));
            put("board", board_id.as_ref().map(|b| json!(b)));
            match code {
                Some(code) => put("code", Some(json!(code))),
                None => put("signal", Some(json!(true))),
            }
        }
        Msg::Bell { term_id, board_id } => {
            put("term", Some(json!(term_id)));
            put("board", board_id.as_ref().map(|b| json!(b)));
        }
        Msg::FileEvent { path, mtime_ms } => {
            put("path", Some(json!(path)));
            put("mtime_ms", Some(json!(mtime_ms)));
        }
        Msg::TermReport { term_id, kind, board_id, .. } => {
            put("term", Some(json!(term_id)));
            if kind.is_some() {
                put("board", board_id.as_ref().map(|b| json!(b)));
                m.extend(report(msg)?);
            }
        }
        _ => return None,
    }
    m.insert("received_ms".into(), json!(received_ms));
    Some(Value::Object(m))
}

/// A report frame's own keys, as `wait --report` prints them; `None` for a
/// frame with no report.
pub(crate) fn report(msg: &Msg) -> Option<Map<String, Value>> {
    let Msg::TermReport { kind: Some(kind), text, at_ms, proc, read, .. } = msg else { return None };
    let mut m = Map::new();
    m.insert("kind".into(), json!(kind));
    if let Some(text) = text {
        m.insert("text".into(), json!(text));
    }
    if let Some(proc) = proc {
        m.insert("proc".into(), json!(proc));
    }
    m.insert("at_ms".into(), json!(at_ms));
    m.insert("read".into(), json!(read));
    Some(m)
}

/// Why a stream ended: a line for stderr with exit 1, or the `--timeout`
/// deadline.
pub(crate) enum Stop {
    Fail(String),
    Late,
}

/// Connects, sends `subscribe` and reads to `ack`: the stream and the
/// snapshot frames before it. Each wait ends at the earlier of 5 s and
/// `deadline`; running out at `deadline` is `Late`.
pub(crate) fn subscribe(kinds: Option<Vec<String>>, term_id: Option<String>, deadline: Option<Instant>) -> Result<(UnixStream, Vec<Msg>), Stop> {
    let five = Instant::now() + crate::DAEMON_WAIT;
    let until = deadline.map_or(five, |d| d.min(five));
    let no_answer = crate::no_answer("an older daemon");
    let timed_out = Cell::new(false);
    let failed = |e: io::Error| {
        timed_out.set(matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut));
        crate::late_or_lost(e, &no_answer)
    };
    let stop = |why: String| match deadline {
        Some(d) if timed_out.get() && Instant::now() >= d => Stop::Late,
        _ => Stop::Fail(why),
    };
    let mut stream = crate::connect_until(until, &failed).map_err(stop)?;
    let payload = proto::encode(&Msg::Subscribe { kinds, term_id }).map_err(|e| Stop::Fail(format!("encode failed: {e}")))?;
    crate::time_out_at(&stream, until).map_err(|e| stop(failed(e)))?;
    frame::write_sync(&mut stream, &payload).map_err(|e| stop(failed(e)))?;
    let mut snapshot = Vec::new();
    loop {
        if !read_until(&stream, Some(until)) {
            return Err(stop(failed(io::ErrorKind::TimedOut.into())));
        }
        match crate::recv_or(&mut stream, &failed).map_err(stop)? {
            Msg::Ack => return Ok((stream, snapshot)),
            Msg::Err { msg } => return Err(Stop::Fail(msg)),
            msg => snapshot.push(msg),
        }
    }
}

/// Gives the next read the time left until `until`, or no limit; false when
/// none is left. macOS refuses a timeout on a socket the peer has closed, and
/// the read that follows says so.
fn read_until(stream: &UnixStream, until: Option<Instant>) -> bool {
    let left = until.map(|u| u.saturating_duration_since(Instant::now()));
    if left.is_some_and(|l| l.is_zero()) {
        return false;
    }
    let _ = stream.set_read_timeout(left);
    true
}

/// The next frame after `ack`. With a `deadline`, running out is `Late`.
pub(crate) fn next(stream: &mut UnixStream, deadline: Option<Instant>) -> Result<Msg, Stop> {
    if !read_until(stream, deadline) {
        return Err(Stop::Late);
    }
    let timed_out = Cell::new(false);
    let msg = crate::recv_or(stream, |e| {
        timed_out.set(matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut));
        crate::lost(e)
    });
    match msg {
        Err(_) if timed_out.get() && deadline.is_some() => Err(Stop::Late),
        Err(why) => Err(Stop::Fail(why)),
        Ok(Msg::Err { msg }) if msg == "lagged" => Err(Stop::Fail(LAGGED.into())),
        Ok(Msg::Err { msg }) => Err(Stop::Fail(msg)),
        Ok(msg) => Ok(msg),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    fn text(msg: &Msg, snapshot: bool) -> String {
        line(msg, snapshot, 9).unwrap().to_string()
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
            (Msg::Exit { term_id: "t1".into(), code: Some(3), board_id: None }, r#"{"event":"exit","term":"t1","code":3,"received_ms":9}"#),
            (Msg::Exit { term_id: "t1".into(), code: None, board_id: Some("b1".into()) }, r#"{"event":"exit","term":"t1","board":"b1","signal":true,"received_ms":9}"#),
            (Msg::Bell { term_id: "t1".into(), board_id: Some("b1".into()) }, r#"{"event":"bell","term":"t1","board":"b1","received_ms":9}"#),
            (Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 }, r#"{"event":"changed","path":"/a.md","mtime_ms":5,"received_ms":9}"#),
            (
                report(Some("done"), Some("ok"), Some("claude"), Some("b1")),
                r#"{"event":"report","term":"t1","board":"b1","kind":"done","text":"ok","proc":"claude","at_ms":7,"read":true,"received_ms":9}"#,
            ),
            (report(Some("blocked"), None, None, None), r#"{"event":"report","term":"t1","kind":"blocked","at_ms":7,"read":true,"received_ms":9}"#),
            (report(None, None, None, None), r#"{"event":"report","term":"t1","received_ms":9}"#),
        ];
        for (msg, want) in cases {
            assert_eq!(text(&msg, false), want, "{msg:?}");
        }
    }

    #[test]
    fn a_snapshot_line_is_marked_after_its_event() {
        let msg = Msg::Bell { term_id: "t1".into(), board_id: None };
        assert_eq!(text(&msg, true), r#"{"event":"bell","snapshot":true,"term":"t1","received_ms":9}"#);
    }

    #[test]
    fn a_frame_that_is_not_an_event_has_no_line() {
        assert!(line(&Msg::Output { term_id: "t1".into(), bytes: vec![] }, false, 9).is_none());
        assert!(line(&Msg::Ack, false, 9).is_none());
    }

    #[test]
    fn the_flags_are_parsed_and_kinds_keep_their_order() {
        assert_eq!(parse(&args(&[])), Some((None, None)));
        assert_eq!(parse(&args(&["--kind", "report,exit", "--term", "t1"])), Some((Some(args(&["report", "exit"])), Some("t1".into()))));
        assert_eq!(parse(&args(&["--term", "t1"])), Some((None, Some("t1".into()))));
    }

    #[test]
    fn a_bad_flag_is_a_usage_error() {
        for bad in [&["--kind", "later"][..], &["--kind", ""], &["--kind", "bell,"], &["--term", "t1", "--kind", "changed"], &["x"], &["--term"], &["--kind"], &["--term", "a", "--term", "b"]] {
            assert_eq!(parse(&args(bad)), None, "{bad:?}");
        }
    }
}
