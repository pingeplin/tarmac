// issue #15: `term_close` terminates a single terminal's pty so ⌘W can close one
// terminal card. The kill is the board-delete path scoped to one term; the killed
// pump runs the normal teardown and pushes Exit. An unknown term_id is a no-op.

mod common;

use common::{Conn, TestDaemon};
use tarmac_protocol::Msg;

// Spawn a long-lived `cat` and prove it is alive by echoing a marker — so a
// following Exit is a real live→dead transition, not a no-op match.
fn spawn_live_cat(app: &mut Conn, term_id: &str) {
    app.spawn_term(term_id, &["/bin/cat"]);
    app.echo_marker(term_id, "alive");
}

// term_close on a live terminal kills its pty: the killed pump pushes an Exit for
// exactly that term_id (the established teardown proof, see boards_integration).
#[test]
fn term_close_kills_term_and_emits_exit() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

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
    let mut app = daemon.connect_app_drained();

    spawn_live_cat(&mut app, "tkeep");
    app.send(&Msg::TermClose { term_id: "nope".into() });

    // The real term still echoes — the unknown close neither crashed the daemon
    // nor tore down a live terminal. If the unknown close had wrongly torn down
    // tkeep, this echo would never arrive and the wait would time out — so the
    // echo IS the no-op proof.
    app.echo_marker("tkeep", "still-here");
}
