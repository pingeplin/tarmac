// End-to-end honest-signal tests: a real daemon spawns a pty and the app receives
// the additive daemon -> app types — `bell` (a BEL in the output) and `term_proc`
// (the foreground process name).

mod common;

use std::time::Instant;

use common::{LONG, TestDaemon, temp_dir};
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

// oh-my-zsh sets the title this way at every prompt (#351). The real BEL comes
// after the debounce window, so a title BEL taken for a bell would make two.
// The pump pushes a chunk's Bell before the Exit frame.
#[test]
fn only_the_bel_outside_an_osc_title_yields_a_bell_frame() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.spawn_term("title-term", &["/bin/sh", "-c", "printf '\\033]2;title\\a'; sleep 0.5; printf '\\a'"]);

    let mut bells = 0;
    app.recv_until("exit", |m| match m {
        Msg::Bell { .. } => {
            bells += 1;
            false
        }
        Msg::Exit { term_id, .. } => term_id == "title-term",
        _ => false,
    });
    assert_eq!(bells, 1);
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

// Claude Code's native install runs `claude` as a symlink to a versioned
// binary: the title is the name it was run by, not the resolved file (#349).
#[test]
fn term_proc_names_a_symlinked_command_by_the_link() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let link = temp_dir().join("claude");
    std::os::unix::fs::symlink("/bin/sleep", &link).unwrap();

    app.spawn_term("link-term", &[link.to_str().unwrap(), "5"]);

    let deadline = Instant::now() + LONG;
    loop {
        match app.recv(deadline, "term_proc") {
            // The pty child is the daemon's fork until it execs.
            Msg::TermProc { term_id, name, .. } if term_id == "link-term" && name != "tarmacd" => {
                assert_eq!(name, "claude");
                break;
            }
            Msg::Exit { term_id, .. } if term_id == "link-term" => panic!("term exited before any term_proc arrived"),
            _ => {}
        }
    }
}
