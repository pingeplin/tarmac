// issue #15: `term_close` terminates a single terminal's pty so ⌘W can close one
// terminal card. The kill is the board-delete path scoped to one term; the killed
// pump runs the normal teardown and pushes Exit. An unknown term_id is a no-op.
// Harness lives in common/.

mod common;

use common::{Conn, TestDaemon};
use tarmac_protocol::Msg;

// Drain the connect-time board_list + restore so later reads see only the frames
// the test drives.
fn drain_connect(app: &mut Conn) {
    app.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
}

// Spawn a long-lived `cat` and prove it is alive by echoing a marker — so a
// following Exit is a real live→dead transition, not a no-op match.
fn spawn_live_cat(app: &mut Conn, term_id: &str) {
    app.send(&Msg::SpawnTerm {
        term_id: term_id.into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/cat".into()]),
        board_id: None,
    });
    app.send(&Msg::Input { term_id: term_id.into(), bytes: b"alive\n".to_vec() });
    app.recv_until("live output", |m| {
        matches!(m, Msg::Output { term_id: t, bytes }
            if t == term_id && common::contains(bytes, b"alive"))
    });
}

// term_close on a live terminal kills its pty: the killed pump pushes an Exit for
// exactly that term_id (the established teardown proof, see m3_integration).
#[test]
fn term_close_kills_term_and_emits_exit() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    spawn_live_cat(&mut app, "tclose");
    app.send(&Msg::TermClose { term_id: "tclose".into() });

    let exit = app.recv_until("exit for the closed term", |m| {
        matches!(m, Msg::Exit { term_id, .. } if term_id == "tclose")
    });
    assert!(matches!(exit, Msg::Exit { term_id, .. } if term_id == "tclose"));
}

// term_close for an unknown term_id is a benign no-op: the daemon stays
// responsive and an unrelated live terminal is untouched (still echoes input).
#[test]
fn term_close_unknown_is_noop() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    spawn_live_cat(&mut app, "tkeep");
    app.send(&Msg::TermClose { term_id: "nope".into() });

    // The real term still echoes — the unknown close neither crashed the daemon
    // nor tore down a live terminal.
    app.send(&Msg::Input { term_id: "tkeep".into(), bytes: b"still-here\n".to_vec() });
    // If the unknown close had wrongly torn down tkeep, this echo would never
    // arrive and recv_until would time out — so the echo IS the no-op proof.
    app.recv_until("survivor still echoes", |m| {
        matches!(m, Msg::Output { term_id, bytes }
            if term_id == "tkeep" && common::contains(bytes, b"still-here"))
    });
}
