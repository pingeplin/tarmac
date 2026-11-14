// `tarmac events` (spec 2611.0012) against a daemon double.

use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::Msg;

mod common;
use common::{Report, Step, Streamer, Then, start, tarmac_at, untouched};

const USAGE: &str = "tarmac: usage: tarmac events [--term ID] [--kind exit,bell,changed,report]\n";

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

fn bell(term_id: &str) -> Msg {
    Msg::Bell { term_id: term_id.into(), board_id: None }
}

fn exit(term_id: &str, code: Option<i64>) -> Msg {
    Msg::Exit { term_id: term_id.into(), code, board_id: None }
}

fn no_report(term_id: &str) -> Msg {
    Msg::TermReport { term_id: term_id.into(), kind: None, text: None, at_ms: None, proc: None, read: false, board_id: None, cwd: None }
}

fn blocked() -> Msg {
    Msg::TermReport {
        term_id: "t1".into(),
        kind: Some("blocked".into()),
        text: Some("May I?".into()),
        at_ms: Some(1_700_000_000_000),
        proc: Some("claude".into()),
        read: false,
        board_id: None,
        cwd: None,
    }
}

/// The line with its `received_ms` taken out, and that value. `received_ms`
/// is the last key.
fn split_received(line: &str) -> (String, u64) {
    let mut v: serde_json::Map<String, serde_json::Value> = serde_json::from_str(line).unwrap();
    assert_eq!(v.keys().last().map(String::as_str), Some("received_ms"), "{line}");
    let ms = v.remove("received_ms").unwrap().as_u64().unwrap();
    (serde_json::to_string(&v).unwrap(), ms)
}

// S12
#[test]
fn s12_each_frame_is_one_json_line_and_the_snapshot_is_marked() {
    let daemon = Streamer::writing(vec![
        blocked(),
        Msg::Ack,
        bell("t1"),
        exit("t1", Some(0)),
        exit("t2", None),
        Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 },
        no_report("t1"),
    ]);
    let before = now_ms();

    let out = daemon.run(&["events"]);

    let after = now_ms();
    let lines: Vec<(String, u64)> = out.stdout.lines().map(split_received).collect();
    assert_eq!(
        lines.iter().map(|(l, _)| l.as_str()).collect::<Vec<_>>(),
        [
            r#"{"event":"report","snapshot":true,"term":"t1","kind":"blocked","text":"May I?","proc":"claude","at_ms":1700000000000,"read":false}"#,
            r#"{"event":"bell","term":"t1"}"#,
            r#"{"event":"exit","term":"t1","code":0}"#,
            r#"{"event":"exit","term":"t2","signal":true}"#,
            r#"{"event":"changed","path":"/a.md","mtime_ms":5}"#,
            r#"{"event":"report","term":"t1"}"#,
        ]
    );
    assert!(lines.iter().all(|(_, ms)| (before..=after).contains(ms)), "{lines:?}");
    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().starts_with("tarmac: daemon connection lost: "), "{}", out.stderr);
    let (request, raw) = daemon.request();
    assert_eq!(request, Msg::Subscribe { kinds: None, term_id: None });
    assert!(!String::from_utf8_lossy(&raw).contains("kinds") && !String::from_utf8_lossy(&raw).contains("term_id"));
}

// S12, and the board of a frame that carries one.
#[test]
fn a_frame_with_a_board_names_it_after_the_terminal() {
    let daemon = Streamer::writing(vec![
        Msg::Ack,
        Msg::Bell { term_id: "t1".into(), board_id: Some("board-1".into()) },
        Msg::Exit { term_id: "t1".into(), code: Some(2), board_id: Some("board-1".into()) },
    ]);

    let out = daemon.run(&["events"]);

    let lines: Vec<String> = out.stdout.lines().map(|l| split_received(l).0).collect();
    assert_eq!(lines, [r#"{"event":"bell","term":"t1","board":"board-1"}"#, r#"{"event":"exit","term":"t1","board":"board-1","code":2}"#]);
}

// S12
#[test]
fn s12_the_filter_flags_are_sent_as_given() {
    let daemon = Streamer::writing(vec![Msg::Ack]);

    daemon.run(&["events", "--term", "t1", "--kind", "exit,bell"]);

    assert_eq!(daemon.request().0, Msg::Subscribe { kinds: Some(vec!["exit".into(), "bell".into()]), term_id: Some("t1".into()) });
}

#[test]
fn frames_the_filter_does_not_take_are_skipped() {
    let daemon = Streamer::writing(vec![Msg::Ack, bell("t2"), exit("t1", Some(0)), bell("t1"), Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 }]);

    let out = daemon.run(&["events", "--term", "t1", "--kind", "bell"]);

    let lines: Vec<String> = out.stdout.lines().map(|l| split_received(l).0).collect();
    assert_eq!(lines, [r#"{"event":"bell","term":"t1"}"#]);
}

// S29
#[test]
fn s29_a_refusal_is_printed_and_exits_1() {
    let daemon = Streamer::writing(vec![Msg::Err { msg: "unknown terminal: t9".into() }]);

    let out = daemon.run(&["events", "--term", "t9"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(1), "", "tarmac: unknown terminal: t9\n"));
}

// S31
#[test]
fn s31_a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    let daemon = Streamer::start(vec![], Then::Hold);
    let started = Instant::now();

    let out = daemon.run(&["events"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: no answer from the daemon in 5 s (an older daemon)\n"));
    assert!(started.elapsed() >= Duration::from_secs(5), "gave up after {:?}", started.elapsed());
}

// S32
#[test]
fn s32_a_lagged_stream_is_named() {
    let daemon = Streamer::writing(vec![Msg::Ack, Msg::Err { msg: "lagged".into() }]);

    let out = daemon.run(&["events"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: the daemon dropped this stream: it fell behind (lagged)\n"));
}

// S33
#[test]
fn s33_a_usage_error_exits_2_with_no_connection() {
    for args in [&["--kind", "later"][..], &["--kind", ""], &["--term", "t1", "--kind", "changed"], &["--term", "t1", "--kind", "bell,changed"], &["extra"], &["--term"], &["--term", "a", "--term", "b"], &["--kind", "bell", "--kind", "exit"]] {
        let daemon = Streamer::writing(vec![Msg::Ack]);

        let out = Report::of(tarmac_at(&daemon.double.sock).arg("events").args(args));

        assert_eq!(out.code(), Some(2), "{args:?}");
        assert_eq!(out.one_stderr_line(), USAGE, "{args:?}");
        assert!(untouched(&daemon.double), "{args:?}");
    }
}

// S35
#[test]
fn s35_a_closed_stdout_ends_events_with_exit_0() {
    let mut steps = vec![Step::Write(Msg::Ack)];
    for _ in 0..100 {
        steps.push(Step::Write(bell("t1")));
        steps.push(Step::Pause(Duration::from_millis(50)));
    }
    let daemon = Streamer::start(steps, Then::Hold);
    let mut child = start(tarmac_at(&daemon.double.sock).arg("events"));

    let mut first = String::new();
    BufReader::new(child.stdout.take().unwrap()).read_line(&mut first).unwrap();
    let closed = Instant::now();

    let deadline = closed + Duration::from_secs(1);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            panic!("events still runs 1 s after its stdout closed");
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let out = child.wait_with_output().unwrap();
    assert!(first.starts_with(r#"{"event":"bell""#), "{first}");
    assert_eq!((status.code(), String::from_utf8_lossy(&out.stderr).as_ref()), (Some(0), ""));
}
