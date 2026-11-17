// `tarmac events` (spec 2611.0012) against a daemon double.

use std::io::{BufRead, BufReader};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::Msg;

mod common;
use common::frames::{bell, exit, term_report};
use common::{Double, Report, Step, Streamer, Then, assert_never_answered, assert_no_answer, assert_usage, start, tarmac_at, untouched};

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// The line with its `received_ms` taken out, and that value. `received_ms`
/// is the last key.
fn split_received(line: &str) -> (String, u64) {
    let mut v: serde_json::Map<String, serde_json::Value> = serde_json::from_str(line).unwrap();
    assert_eq!(v.keys().last().map(String::as_str), Some("received_ms"), "{line}");
    let ms = v.remove("received_ms").unwrap().as_u64().unwrap();
    (serde_json::to_string(&v).unwrap(), ms)
}

fn lines(out: &Report) -> Vec<String> {
    out.stdout.lines().map(|l| split_received(l).0).collect()
}

// S12
#[test]
fn s12_each_frame_is_one_json_line_and_the_snapshot_is_marked() {
    let daemon = Streamer::writing(vec![
        term_report("t1", Some("blocked"), Some("May I?"), Some("claude"), false),
        Msg::Ack,
        bell("t1"),
        exit("t1", Some(0)),
        exit("t2", None),
        Msg::FileEvent { path: "/a.md".into(), mtime_ms: 5 },
        term_report("t1", None, None, None, false),
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

    assert_eq!(lines(&out), [r#"{"event":"bell","term":"t1","board":"board-1"}"#, r#"{"event":"exit","term":"t1","board":"board-1","code":2}"#]);
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

    assert_eq!(lines(&out), [r#"{"event":"bell","term":"t1"}"#]);
}

// After `ack` the stream has no time limit: the 5 s wait is for the answer.
#[test]
fn a_stream_quiet_for_longer_than_5_s_goes_on() {
    let daemon = Streamer::start(vec![Step::Write(Msg::Ack), Step::Pause(Duration::from_millis(5500)), Step::Write(bell("t1"))], Then::Close);

    let out = daemon.run(&["events"]);

    assert_eq!(lines(&out), [r#"{"event":"bell","term":"t1"}"#], "{}", out.stderr);
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
    assert_never_answered(&["events"]);
}

// S32
#[test]
fn s32_a_lagged_stream_is_named() {
    let daemon = Streamer::writing(vec![Msg::Ack, Msg::Err { msg: "lagged".into() }]);

    let out = daemon.run(&["events"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: the daemon dropped this stream: it fell behind (lagged)\n"));
}

// S33: the whole matrix is `parse`'s unit test.
#[test]
fn s33_a_usage_error_exits_2_with_no_connection() {
    let daemon = Streamer::writing(vec![Msg::Ack]);

    assert_usage(&Report::of(tarmac_at(&daemon.double.sock).args(["events", "--term", "t1", "--kind", "changed"])), "events");
    assert!(untouched(&daemon.double));
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

    let deadline = Instant::now() + Duration::from_secs(1);
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

// Unlike `terms`, a time-out in the handshake is the no-answer line.
#[test]
fn a_daemon_silent_to_hello_is_the_no_answer_line_after_5_s() {
    let daemon = Double::start("tarmacd.sock", |peer| peer.hold());
    let started = Instant::now();

    assert_no_answer(&Report::of(tarmac_at(&daemon.sock).arg("events")), started);
}
