// `tarmac resume` (spec 2611.0011) against a daemon double. The daemon's own
// answers are its tests' business; here the subject is what the cli sends,
// prints and exits with.

use std::time::Instant;

use tarmac_protocol::{self as proto, Msg};

mod common;
use common::{Answer, Double, OneAnswer, Report, assert_no_answer, no_daemon_line, tarmac_at, without_daemon};

const USAGE: &str = "tarmac: usage: tarmac resume set \"<command>\"  |  tarmac resume clear\n";
const NEEDS_TERM: &str = "tarmac: resume needs TARMAC_TERM_ID (run it in a Tarmac terminal)\n";

fn no_daemon(term_id: Option<&str>, args: &[&str]) -> Report {
    without_daemon("resume", term_id, args)
}

fn resume(cmd: Option<&str>) -> Msg {
    Msg::Resume { term_id: "t9".into(), cmd: cmd.map(str::to_string) }
}

// "Resume verb sends set and clear"
#[test]
fn set_sends_the_command_for_the_calling_terminal_and_prints_nothing() {
    let daemon = OneAnswer::acking();
    let out = daemon.run("resume", &["set", "claude --resume ab-12"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    assert_eq!(proto::decode(&daemon.sent()).unwrap(), resume(Some("claude --resume ab-12")));
}

// "Resume verb sends set and clear"
#[test]
fn clear_sends_no_cmd_key() {
    let daemon = OneAnswer::acking();
    let out = daemon.run("resume", &["clear"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    let sent = daemon.sent();
    assert!(!sent.windows(3).any(|w| w == b"cmd"), "{sent:02x?}");
    assert_eq!(proto::decode(&sent).unwrap(), resume(None));
}

// "CLI usage errors exit 2"
#[test]
fn a_usage_error_exits_2_and_does_not_connect() {
    for args in [&[][..], &["frob"], &["set"], &["set", "a", "b"], &["clear", "x"]] {
        let out = no_daemon(Some("t9"), args);

        assert_eq!(out.code(), Some(2), "{args:?}");
        assert_eq!(out.one_stderr_line(), USAGE, "{args:?}");
    }
}

// "CLI usage errors exit 2"
#[test]
fn a_refused_command_exits_2_with_its_cause_and_does_not_connect() {
    let long = "a".repeat(257);
    for (cmd, cause) in [
        ("a\nb", "a control character"),
        ("", "empty"),
        ("echo \u{202e}x", "an invisible format character"),
        (long.as_str(), "over 256 characters"),
    ] {
        let out = no_daemon(Some("t9"), &["set", cmd]);

        assert_eq!(out.code(), Some(2), "{cmd:?}");
        assert_eq!(out.one_stderr_line(), format!("tarmac: resume command refused: {cause}\n"), "{cmd:?}");
    }
}

// "CLI usage errors exit 2"
#[test]
fn the_usage_check_comes_before_the_terminal_check() {
    let out = no_daemon(None, &["frob"]);
    assert_eq!((out.code(), out.stderr.as_str()), (Some(2), USAGE));
}

// "CLI failures exit 1"
#[test]
fn no_terminal_exits_1_and_does_not_connect() {
    for term_id in [None, Some("")] {
        let out = no_daemon(term_id, &["set", "echo HI"]);

        assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NEEDS_TERM), "{term_id:?}");
    }
}

/// The daemon gives no such id, so the verb is not in a Tarmac terminal.
#[test]
fn a_term_id_that_is_not_utf8_is_no_terminal() {
    use std::os::unix::ffi::OsStrExt;
    let out = without_daemon("resume", Some(std::ffi::OsStr::from_bytes(b"t\xff9")), &["set", "echo HI"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NEEDS_TERM));
}

// "CLI failures exit 1"
#[test]
fn the_daemons_refusal_is_printed_and_exits_1() {
    let daemon = OneAnswer::start(Answer::Reply(Msg::Err { msg: "unknown terminal: t9".into() }));
    let out = daemon.run("resume", &["set", "echo HI"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: unknown terminal: t9\n"));
}

// "CLI failures exit 1"
#[test]
fn no_daemon_is_the_no_daemon_line() {
    let sock = common::scratch().join("absent.sock");
    let out = Report::of(tarmac_at(&sock).env("TARMAC_TERM_ID", "t9").args(["resume", "clear"]));

    assert_eq!(out.code(), Some(1));
    assert_eq!(out.stderr, no_daemon_line(&sock));
}

// "CLI failures exit 1"
#[test]
fn a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    let daemon = OneAnswer::start(Answer::Silence);
    let started = Instant::now();
    let out = daemon.run("resume", &["set", "echo HI"]);

    assert_no_answer(&out, started);
}

// A time-out in the handshake is no answer, as one after it is.
#[test]
fn a_daemon_silent_to_hello_is_the_no_answer_line_after_5_s() {
    let daemon = Double::start("tarmacd.sock", |peer| peer.hold());
    let started = Instant::now();
    let out = Report::of(tarmac_at(&daemon.sock).env("TARMAC_TERM_ID", "t9").args(["resume", "clear"]));

    assert_no_answer(&out, started);
}
