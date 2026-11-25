// `tarmac terms` (spec 2611.0012) against a daemon double.

use std::time::Instant;

use tarmac_protocol::{Msg, TermInfo};

mod common;
use common::{Double, Report, Streamer, assert_never_answered, assert_no_answer, assert_usage, tarmac_at, untouched};

fn row(cwd: Option<&str>, proc: Option<&str>) -> TermInfo {
    TermInfo {
        term_id: "t1".into(),
        board_id: "board-0".into(),
        cwd: cwd.map(str::to_string),
        proc: proc.map(str::to_string),
    }
}

// "Terms CLI prints one line per terminal"
#[test]
fn each_row_is_one_json_line_in_the_daemons_order() {
    let daemon = Streamer::writing(vec![Msg::Terms { terms: vec![row(Some("/w"), Some("zsh")), row(None, None)] }]);

    let out = daemon.run(&["terms"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""));
    assert_eq!(
        out.stdout,
        "{\"term\":\"t1\",\"board\":\"board-0\",\"cwd\":\"/w\",\"proc\":\"zsh\"}\n{\"term\":\"t1\",\"board\":\"board-0\"}\n"
    );
    assert_eq!(daemon.request().0, Msg::TermsList);
}

// "Terms CLI prints one line per terminal"
#[test]
fn no_terminal_prints_nothing() {
    let daemon = Streamer::writing(vec![Msg::Terms { terms: vec![] }]);

    let out = daemon.run(&["terms"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
}

#[test]
fn a_refusal_is_printed_and_exits_1() {
    let daemon = Streamer::writing(vec![Msg::Err { msg: "no".into() }]);

    let out = daemon.run(&["terms"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: no\n"));
}

// "Wait timeouts exit 124"
#[test]
fn a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    assert_never_answered(&["terms"]);
}

// "Bad wait usage exits 2"
#[test]
fn an_argument_is_a_usage_error_with_no_connection() {
    let daemon = Streamer::writing(vec![]);

    assert_usage(&Report::of(tarmac_at(&daemon.double.sock).args(["terms", "extra"])), "terms");
    assert!(untouched(&daemon.double));
}

// As for `events` and `wait`, a time-out in the handshake is no answer.
#[test]
fn a_daemon_silent_to_hello_is_the_no_answer_line_after_5_s() {
    let daemon = Double::start("tarmacd.sock", |peer| peer.hold());
    let started = Instant::now();
    let out = Report::of(tarmac_at(&daemon.sock).arg("terms"));

    assert_no_answer(&out, started);
}
