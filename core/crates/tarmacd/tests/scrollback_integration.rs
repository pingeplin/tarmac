// On-demand scrollback replay (issue #41): the daemon answers a
// `scrollback_request` with exactly one `scrollback` frame carrying that term's
// ring — always, even for an empty ring or an unknown term — and that answer is
// independent of the per-connection one-time board replay. Harness in common/.

mod common;

use std::time::Duration;

use common::{Conn, TestDaemon, contains, none_within};
use tarmac_protocol::Msg;

const QUIET: Duration = Duration::from_millis(400);

fn spawn_term(app: &mut Conn, term_id: &str, cmd: Vec<String>, board_id: Option<String>) {
    app.send(&Msg::SpawnTerm {
        term_id: term_id.into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(cmd),
        board_id,
        inherit_cwd_from: None,
    });
}

fn drain_board(app: &mut Conn) {
    app.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
}

// Echo `marker` through a live `cat` and wait until the daemon has seen it, so
// the ring is known to hold it before we ask for a snapshot.
fn echo_marker(app: &mut Conn, term_id: &str, marker: &str) {
    app.send(&Msg::Input { term_id: term_id.into(), bytes: format!("{marker}\n").into_bytes() });
    app.recv_until("echoed marker", |m| {
        matches!(m, Msg::Output { term_id: t, bytes } if t == term_id && contains(bytes, marker.as_bytes()))
    });
}

// Drain live output until the pty has been quiet for QUIET, so the ring is
// settled and no in-flight push can land on a later connection.
fn quiesce(app: &mut Conn, term_id: &str) {
    while !none_within(app, QUIET, |m| matches!(m, Msg::Output { term_id: t, .. } if t == term_id)) {}
}

fn request_scrollback(app: &mut Conn, term_id: &str) -> Vec<u8> {
    app.send(&Msg::ScrollbackRequest { term_id: term_id.into() });
    let msg = app.recv_until("scrollback", |m| {
        matches!(m, Msg::Scrollback { term_id: t, .. } if t == term_id)
    });
    let Msg::Scrollback { bytes, .. } = msg else { unreachable!() };
    bytes
}

// S1: a live term's ring comes back in one frame that contains what it printed,
// and exactly one frame — a second reply would duplicate history in the xterm.
#[test]
fn scrollback_request_replies_once_with_the_ring() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_board(&mut app);

    spawn_term(&mut app, "t1", vec!["/bin/cat".into()], None);
    echo_marker(&mut app, "t1", "MARKER-ONE");

    let bytes = request_scrollback(&mut app, "t1");
    assert!(
        contains(&bytes, b"MARKER-ONE"),
        "the reply must carry the term's ring, got {} bytes",
        bytes.len()
    );
    assert!(
        none_within(&mut app, QUIET, |m| matches!(m, Msg::Scrollback { term_id, .. } if term_id == "t1")),
        "one request must produce exactly one scrollback frame"
    );
}

// S5: an unknown term and a live-but-silent term both answer with empty bytes.
// Silence would leave the app awaiting forever, blanking a card.
#[test]
fn scrollback_request_answers_unknown_and_silent_terms_with_empty_bytes() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_board(&mut app);

    assert!(request_scrollback(&mut app, "no-such-term").is_empty());

    // A default shell prints a prompt within milliseconds; `sleep` never does.
    spawn_term(&mut app, "tquiet", vec!["/bin/sleep".into(), "30".into()], None);
    assert!(request_scrollback(&mut app, "tquiet").is_empty());

    // The daemon is still healthy — no err frame, and it still serves requests.
    spawn_term(&mut app, "tloud", vec!["/bin/cat".into()], None);
    echo_marker(&mut app, "tloud", "STILL-ALIVE");
    assert!(contains(&request_scrollback(&mut app, "tloud"), b"STILL-ALIVE"));
}

// S6: the request neither consumes nor sets AppConn.replayed — a board visited
// for the first time after a request still gets its one-time Output replay, and
// a switch away and back still gets none.
#[test]
fn scrollback_request_leaves_the_one_time_board_replay_intact() {
    let daemon = TestDaemon::start();

    // Connection A builds board-1 with a live, noisy term, then leaves board-0
    // active so a fresh connection has never visited board-1.
    {
        let mut app = Conn::hello(&daemon.sock, "app");
        drain_board(&mut app);
        app.send(&Msg::BoardCreate);
        drain_board(&mut app);
        spawn_term(&mut app, "tb1", vec!["/bin/cat".into()], Some("board-1".into()));
        echo_marker(&mut app, "tb1", "BOARD-ONE-HISTORY");
        // `cat`'s own copy of the line trails the tty echo; a push still in
        // flight would land on the next connection and look like a second replay.
        quiesce(&mut app, "tb1");
        app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
        drain_board(&mut app);
    }

    let mut app = Conn::hello(&daemon.sock, "app");
    drain_board(&mut app);

    // Serving a request for a term on a not-yet-visited board must not mark it.
    assert!(contains(&request_scrollback(&mut app, "tb1"), b"BOARD-ONE-HISTORY"));

    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    let restore = app.recv_until("board-1 restore", |m| {
        matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some("board-1"))
    });
    let Msg::Restore { live_terms, .. } = restore else { unreachable!() };
    assert_eq!(live_terms, vec!["tb1".to_string()]);
    app.recv_until("first-visit replay", |m| {
        matches!(m, Msg::Output { term_id, bytes } if term_id == "tb1" && contains(bytes, b"BOARD-ONE-HISTORY"))
    });

    // A second request, served BEFORE the switch-back below, so that an arm which
    // cleared `replayed` would re-arm board-1 and be caught by the assertion.
    assert!(contains(&request_scrollback(&mut app, "tb1"), b"BOARD-ONE-HISTORY"));

    // Switch away and back: still replayed exactly once per connection.
    for board in ["board-0", "board-1"] {
        app.send(&Msg::BoardSwitch { board_id: board.into() });
        app.recv_until("restore", |m| {
            matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some(board))
        });
    }
    assert!(
        none_within(&mut app, QUIET, |m| matches!(m, Msg::Output { term_id, .. } if term_id == "tb1")),
        "a switch-back must not replay the board a second time"
    );
}
