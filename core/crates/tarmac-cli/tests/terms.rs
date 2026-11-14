// `tarmac terms` (spec 2611.0012) against a daemon double.

use std::time::{Duration, Instant};

use tarmac_protocol::{Msg, TermInfo};

mod common;
use common::{Report, Step, Streamer, Then, tarmac_at, untouched};

const NO_ANSWER: &str = "tarmac: no answer from the daemon in 5 s (an older daemon)\n";

fn row(cwd: Option<&str>, proc: Option<&str>) -> TermInfo {
    TermInfo { term_id: "t1".into(), board_id: "board-0".into(), cwd: cwd.map(str::to_string), proc: proc.map(str::to_string) }
}

// S14
#[test]
fn s14_each_row_is_one_json_line_in_the_daemons_order() {
    let daemon = Streamer::writing(vec![Msg::Terms { terms: vec![row(Some("/w"), Some("zsh")), row(None, None)] }]);

    let out = daemon.run(&["terms"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""));
    assert_eq!(out.stdout, "{\"term\":\"t1\",\"board\":\"board-0\",\"cwd\":\"/w\",\"proc\":\"zsh\"}\n{\"term\":\"t1\",\"board\":\"board-0\"}\n");
    assert_eq!(daemon.request().0, Msg::TermsList);
}

// S14
#[test]
fn s14_no_terminal_prints_nothing() {
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

// S31
#[test]
fn s31_a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    let daemon = Streamer::start(vec![], Then::Hold);
    let started = Instant::now();

    let out = daemon.run(&["terms"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), NO_ANSWER));
    assert!(started.elapsed() >= Duration::from_secs(5), "gave up after {:?}", started.elapsed());
}

// S33
#[test]
fn s33_an_argument_is_a_usage_error_with_no_connection() {
    let daemon = Streamer::start(vec![Step::Pause(Duration::ZERO)], Then::Close);

    let out = Report::of(tarmac_at(&daemon.double.sock).args(["terms", "extra"]));

    assert_eq!(out.code(), Some(2));
    assert_eq!(out.one_stderr_line(), "tarmac: usage: tarmac terms\n");
    assert!(untouched(&daemon.double));
}
