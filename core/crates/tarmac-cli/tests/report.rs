// `tarmac report` (spec 2611.0009) against a daemon double. The daemon's own
// answers are its tests' business; here the subject is what the cli sends,
// prints and exits with.

use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg, REPORT_TEXT_MAX};

mod common;
use common::{Answer, OneAnswer, Report, channel, tarmac, tarmac_at};

const USAGE: &str = "tarmac: usage: tarmac report blocked|done [\"<text>\"]  |  tarmac report clear\n";
const NEEDS_TERM: &str = "tarmac: report needs TARMAC_TERM_ID (run it in a Tarmac terminal)\n";
const NO_ANSWER: &str = "tarmac: no answer from the daemon in 5 s (an older daemon)\n";

/// `tarmac report` on a socket that is absent: a run that tried to connect
/// would print the no-daemon line instead of the one asserted.
fn no_daemon(term_id: Option<&str>, args: &[&str]) -> Report {
    let mut cmd = tarmac();
    cmd.env_remove("TARMAC_TERM_ID");
    if let Some(term_id) = term_id {
        cmd.env("TARMAC_TERM_ID", term_id);
    }
    Report::of(cmd.arg("report").args(args))
}

fn report(kind: &str, text: Option<&str>) -> Msg {
    Msg::Report { term_id: "t9".into(), kind: kind.into(), text: text.map(str::to_string) }
}

fn has(bytes: &[u8], needle: &[u8]) -> bool {
    bytes.windows(needle.len()).any(|w| w == needle)
}

// S6
#[test]
fn s6_a_report_is_sent_for_the_calling_terminal_and_success_prints_nothing() {
    let daemon = OneAnswer::acking();
    let out = daemon.run("report", &["blocked", "May I?"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    assert_eq!(proto::decode(&daemon.sent()).unwrap(), report("blocked", Some("May I?")));
}

// S6
#[test]
fn s6_clear_and_a_report_with_no_or_an_empty_text_send_no_text_key() {
    for (args, kind) in [(&["clear"][..], "clear"), (&["done"], "done"), (&["done", ""], "done"), (&["clear", ""], "clear")] {
        let daemon = OneAnswer::acking();
        let out = daemon.run("report", args);

        assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""), "{args:?}");
        let sent = daemon.sent();
        assert!(!has(&sent, b"text"), "{args:?}: {sent:02x?}");
        assert_eq!(proto::decode(&sent).unwrap(), report(kind, None), "{args:?}");
    }
}

// S22
#[test]
fn s22_a_usage_error_exits_2_and_does_not_connect() {
    for args in [&[][..], &["later"], &["clear", "x"], &["done", "a", "b"], &["clear", "", ""]] {
        let out = no_daemon(Some("t9"), args);

        assert_eq!(out.code(), Some(2), "{args:?}");
        assert_eq!(out.one_stderr_line(), USAGE, "{args:?}");
    }
}

// S23
#[test]
fn s23_no_terminal_exits_1_and_does_not_connect() {
    for term_id in [None, Some("")] {
        let out = no_daemon(term_id, &["done", "x"]);

        assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NEEDS_TERM), "{term_id:?}");
    }
}

#[test]
fn a_usage_error_comes_before_the_terminal_check() {
    let out = no_daemon(None, &["later"]);
    assert_eq!((out.code(), out.stderr.as_str()), (Some(2), USAGE));
}

// S24
#[test]
fn s24_the_daemons_refusal_is_printed_and_exits_1() {
    let daemon = OneAnswer::start(Answer::Reply(Msg::Err { msg: "unknown terminal: t9".into() }));
    let out = daemon.run("report", &["done"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: unknown terminal: t9\n"));
}

// S24
#[test]
fn s24_no_daemon_is_the_no_daemon_line() {
    let sock = common::scratch().join("absent.sock");
    let out = Report::of(tarmac_at(&sock).env("TARMAC_TERM_ID", "t9").args(["report", "done"]));

    assert_eq!(out.code(), Some(1));
    assert_eq!(
        out.stderr,
        format!("tarmac: no tarmac daemon running ({} channel, socket: {})\n", channel(), sock.display())
    );
}

// S24
#[test]
fn s24_a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    let daemon = OneAnswer::start(Answer::Silence);
    let started = Instant::now();
    let out = daemon.run("report", &["done"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NO_ANSWER));
    assert!(started.elapsed() >= Duration::from_secs(5), "gave up after {:?}", started.elapsed());
}

// S25
#[test]
fn s25_the_cli_caps_a_long_text() {
    let daemon = OneAnswer::acking();
    // Three bytes a char: a cap by bytes would keep 93 chars, or split one.
    let out = daemon.run("report", &["blocked", &"中".repeat(400)]);

    assert_eq!(out.code(), Some(0), "stderr: {}", out.stderr);
    let capped = format!("{}…", "中".repeat(REPORT_TEXT_MAX - 1));
    assert_eq!(proto::decode(&daemon.sent()).unwrap(), report("blocked", Some(&capped)));
}
