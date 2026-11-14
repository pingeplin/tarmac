// End-to-end honest-signal tests: a real daemon spawns a pty and the app receives
// the additive daemon -> app types — `bell` (a BEL in the output) and `term_proc`
// (the foreground process name).

mod common;

use std::time::Instant;

use common::{LONG, TestDaemon};
use tarmac_protocol::Msg;

#[test]
fn bel_in_output_yields_a_bell_frame() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // printf '\a' writes a BEL (0x07) to the pty; the daemon scans the
    // forwarded chunk and pushes a Bell frame for this term.
    app.spawn_term("bell-term", &["/bin/sh", "-c", "printf '\\a'; sleep 0.2"]);

    let bell = app.recv_until("bell", |m| matches!(m, Msg::Bell { .. }));
    let Msg::Bell { term_id } = bell else { unreachable!() };
    assert_eq!(term_id, "bell-term");
}

// oh-my-zsh sets the title this way at every prompt (#351). The pump pushes a
// chunk's Bell before the Exit frame, so no Bell before Exit means none at all.
#[test]
fn bel_that_ends_an_osc_title_yields_no_bell_frame() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.spawn_term("title-term", &["/bin/sh", "-c", "printf '\\033]2;title\\a'"]);

    let first = app.recv_until("bell or exit", |m| {
        matches!(m, Msg::Bell { .. }) || matches!(m, Msg::Exit { term_id, .. } if term_id == "title-term")
    });
    assert!(matches!(first, Msg::Exit { .. }), "expected no Bell before Exit, got {first:?}");
}

#[test]
fn term_proc_reports_a_foreground_process_name() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // A shell that lingers long enough for the ~750ms process-name poll to run
    // at least once. The specific name can be flaky (sh vs sleep vs the login
    // shell), so assert only that SOME term_proc arrives with a plausible name.
    app.spawn_term("proc-term", &["/bin/sh", "-c", "sleep 2"]);

    let deadline = Instant::now() + LONG;
    loop {
        match app.recv(deadline, "term_proc") {
            Msg::TermProc { term_id, name, .. } if term_id == "proc-term" => {
                assert!(!name.is_empty(), "term_proc name should not be empty");
                // A basename: no path separators, no NULs.
                assert!(!name.contains('/'), "term_proc name should be a basename, got {name:?}");
                break;
            }
            Msg::Exit { term_id, .. } if term_id == "proc-term" => {
                panic!("term exited before any term_proc arrived");
            }
            _ => {}
        }
    }
}
