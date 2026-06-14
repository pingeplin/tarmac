// End-to-end M2 honest-signal tests: a real daemon spawns a pty and the app
// receives the additive daemon -> app types — `bell` (a BEL in the output) and
// `term_proc` (the foreground process name). Harness lives in common/.

mod common;

use std::time::Instant;

use common::{Conn, LONG, TestDaemon};
use tarmac_protocol::Msg;

#[test]
fn bel_in_output_yields_a_bell_frame() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    // printf '\a' writes a BEL (0x07) to the pty; the daemon scans the
    // forwarded chunk and pushes a Bell frame for this term.
    app.send(&Msg::SpawnTerm {
        term_id: "bell-term".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "printf '\\a'; sleep 0.2".into()]),
        board_id: None,
    });

    let bell = app.recv_until("bell", |m| matches!(m, Msg::Bell { .. }));
    let Msg::Bell { term_id } = bell else { unreachable!() };
    assert_eq!(term_id, "bell-term");
}

#[test]
fn term_proc_reports_a_foreground_process_name() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    // A shell that lingers long enough for the ~750ms process-name poll to run
    // at least once. The specific name can be flaky (sh vs sleep vs the login
    // shell), so assert only that SOME term_proc arrives with a plausible name.
    app.send(&Msg::SpawnTerm {
        term_id: "proc-term".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 2".into()]),
        board_id: None,
    });

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
