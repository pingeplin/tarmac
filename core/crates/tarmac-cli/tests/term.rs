// `tarmac term new` (spec 2611.0016) against a daemon double: what the cli
// sends, prints and exits with.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use tarmac_protocol::{self as proto, Msg};

mod common;
use common::{Answer, OneAnswer, Report, assert_no_answer, scratch, tarmac_at, untouched};

const USAGE: &str = "tarmac: usage: tarmac term new [--cwd DIR] \"<command>\"\n";

fn answering(term_id: &str) -> OneAnswer {
    OneAnswer::start(Answer::Reply(Msg::TermNewOk { req_id: None, term_id: term_id.into() }))
}

/// A real directory `/…/w/<sub>`, as the cli reads its own: resolved.
fn dir(sub: &str) -> PathBuf {
    let dir = scratch().join("w").join(sub);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// `tarmac term new <args>` run in `cwd`, outside any Tarmac terminal.
fn run_in(sock: &Path, cwd: &Path, args: &[&str]) -> Report {
    Report::of(tarmac_at(sock).env_remove("TARMAC_TERM_ID").current_dir(cwd).args(["term", "new"]).args(args))
}

fn sent(daemon: &OneAnswer) -> Msg {
    proto::decode(&daemon.sent()).unwrap()
}

fn term_new(cmd: &str, cwd: &Path, term_id: Option<&str>) -> Msg {
    Msg::TermNew {
        req_id: None,
        cmd: cmd.into(),
        cwd: cwd.to_str().unwrap().into(),
        term_id: term_id.map(str::to_string),
        board_id: None,
    }
}

// S4
#[test]
fn s4_the_request_names_the_callers_folder_and_terminal_and_the_new_id_is_one_json_line() {
    let daemon = answering("t9");
    let api = dir("api");

    let out = Report::of(tarmac_at(&daemon.double.sock).env("TARMAC_TERM_ID", "t1").current_dir(&api).args(["term", "new", "claude"]));

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "{\"term\":\"t9\"}\n", ""));
    assert_eq!(sent(&daemon), term_new("claude", &api, Some("t1")));
}

#[test]
fn outside_a_tarmac_terminal_the_request_names_no_terminal() {
    let daemon = answering("t9");
    let w = dir("");

    run_in(&daemon.double.sock, &w, &["claude"]);

    assert_eq!(sent(&daemon), term_new("claude", &w, None));
}

// S5
#[test]
fn s5_a_relative_cwd_is_taken_from_the_clis_folder_and_is_not_read() {
    let daemon = answering("t9");
    let w = dir("");

    run_in(&daemon.double.sock, &w, &["--cwd", "api", "x"]);

    assert_eq!(sent(&daemon), term_new("x", &w.join("api"), None));
}

// S5
#[test]
fn s5_an_absolute_cwd_is_sent_as_it_is() {
    let daemon = answering("t9");

    run_in(&daemon.double.sock, &dir(""), &["--cwd", "/abs/dir", "x"]);

    assert_eq!(sent(&daemon), term_new("x", Path::new("/abs/dir"), None));
}

#[test]
fn the_daemons_refusal_is_printed_and_exits_1() {
    let daemon = OneAnswer::start(Answer::Reply(Msg::Err { msg: "no app connected".into() }));

    let out = run_in(&daemon.double.sock, &dir(""), &["x"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(1), "", "tarmac: no app connected\n"));
}

// S19
#[test]
fn s19_a_refused_command_exits_2_with_its_cause_and_does_not_connect() {
    let long = "x".repeat(4097);
    for (cmd, cause) in [
        ("", "empty"),
        ("   ", "empty"),
        ("echo a\necho b", "a control character"),
        ("echo a\rb", "a control character"),
        ("echo \u{1b}[2J", "a control character"),
        ("echo a\u{2028}b", "a control character"),
        ("echo \u{200b}x", "an invisible format character"),
        (long.as_str(), "over 4096 characters"),
    ] {
        let daemon = answering("t9");

        let out = run_in(&daemon.double.sock, &dir(""), &[cmd]);

        assert_eq!((out.code(), out.stderr), (Some(2), format!("tarmac: term new command refused: {cause}\n")), "{cmd:?}");
        assert!(untouched(&daemon.double), "{cmd:?}");
    }
}

// S19
#[test]
fn s19_a_command_of_exactly_4096_chars_is_sent() {
    let daemon = answering("t9");
    let cmd = "中".repeat(4096);

    let out = run_in(&daemon.double.sock, &dir(""), &[&cmd]);

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
}

// S21
#[test]
fn s21_a_usage_error_exits_2_and_does_not_connect() {
    for args in [&["term"][..], &["term", "new"], &["term", "new", "a", "b"], &["term", "new", "--frob", "a"], &["term", "new", "--cwd"], &["term", "new", "--cwd", "", "a"], &["term", "old", "a"]] {
        let daemon = answering("t9");

        let out = Report::of(tarmac_at(&daemon.double.sock).args(args));

        assert_eq!((out.code(), out.stderr.as_str()), (Some(2), USAGE), "{args:?}");
        assert!(untouched(&daemon.double), "{args:?}");
    }
}

// S22
#[test]
fn s22_a_daemon_that_never_answers_is_the_no_answer_line_after_5_s() {
    let daemon = OneAnswer::start(Answer::Silence);
    let started = Instant::now();

    let out = run_in(&daemon.double.sock, &dir(""), &["x"]);

    assert_no_answer(&out, started);
}

/// `tarmac term new <args>` in a folder removed after the shell entered it.
fn in_a_removed_folder(sock: &Path, args: &str) -> Report {
    let gone = dir("gone");
    let script = format!("cd \"$1\" && rmdir \"$1\" && exec \"$2\" term new {args}");
    Report::of(
        Command::new("/bin/sh")
            .args(["-c", &script, "sh", gone.to_str().unwrap(), env!("CARGO_BIN_EXE_tarmac")])
            .env("TARMAC_SOCKET", sock)
            .env_remove("TARMAC_TERM_ID"),
    )
}

// S29
#[test]
fn s29_with_no_readable_folder_and_no_absolute_cwd_the_cli_exits_1_and_does_not_connect() {
    for args in ["x", "--cwd api x"] {
        let daemon = answering("t9");

        let out = in_a_removed_folder(&daemon.double.sock, args);

        assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: cannot read the current directory\n"), "{args}");
        assert!(untouched(&daemon.double), "{args}");
    }
}

// S29
#[test]
fn s29_an_absolute_cwd_needs_no_readable_folder() {
    let daemon = answering("t9");

    let out = in_a_removed_folder(&daemon.double.sock, "--cwd /abs/dir x");

    assert_eq!((out.code(), out.stdout.as_str()), (Some(0), "{\"term\":\"t9\"}\n"), "{}", out.stderr);
}
