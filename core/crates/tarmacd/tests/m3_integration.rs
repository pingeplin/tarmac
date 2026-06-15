// End-to-end M3 tests: multiple boards ("strips = boards"). board_list on
// connect, board_create / board_switch, per-board layout that persists
// independently across a daemon restart, and `tarmac open` provenance routing
// the doc to the calling term's board. Harness lives in common/.

mod common;

use std::path::Path;
use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon};
use tarmac_protocol::{BoardMeta, BoardViewport, DocEntry, Msg, Tile};

fn write_doc(path: &Path, content: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

fn term_tile(term_id: &str, x: f64) -> Tile {
    Tile {
        kind: "term".into(),
        path: None,
        x: Some(x),
        y: Some(80.0),
        w: Some(470.0),
        h: Some(330.0),
        z: Some(0),
        loose: None,
        shelf: None,
        term_id: Some(term_id.into()),
    }
}

fn doc_tile(path: &str) -> Tile {
    Tile {
        kind: "doc".into(),
        path: Some(path.into()),
        x: Some(648.0),
        y: Some(80.0),
        w: Some(392.0),
        h: Some(310.0),
        z: Some(1),
        loose: None,
        shelf: None,
        term_id: None,
    }
}

// A fresh cli connection opens a doc on the active board (no TARMAC_TERM_ID).
fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
}

fn recv_board_list(app: &mut Conn) -> (Vec<BoardMeta>, String) {
    let msg = app.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
    let Msg::BoardList { boards, active } = msg else { unreachable!() };
    (boards, active)
}

#[allow(clippy::type_complexity)]
fn recv_restore(app: &mut Conn) -> (Option<String>, Vec<DocEntry>, Vec<Tile>, Option<BoardViewport>) {
    let msg = app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { board_id, docs, tiles, board, .. } = msg else { unreachable!() };
    (board_id, docs, tiles, board)
}

fn board_ids(boards: &[BoardMeta]) -> Vec<&str> {
    boards.iter().map(|b| b.board_id.as_str()).collect()
}

// Persistence is debounced; poll the state file until it reflects the expected
// facts before SIGKILL-restarting the daemon (else the save can race the kill).
fn wait_for_state(state: &Path, what: &str, pred: impl Fn(&serde_json::Value) -> bool) {
    let deadline = Instant::now() + LONG;
    loop {
        if let Ok(bytes) = std::fs::read(state)
            && let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes)
            && pred(&v)
        {
            return;
        }
        assert!(Instant::now() < deadline, "state file never showed {what}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn doc_paths(docs: &[DocEntry]) -> Vec<&str> {
    docs.iter().map(|d| d.path.as_str()).collect()
}

// The P2 acceptance: two boards each keep their own docs/tiles/viewport across
// a daemon restart, board_create/switch behave, and `tarmac open` from a term
// on board-1 lands the doc on board-1 even when board-0 is active.
#[test]
fn boards_create_switch_route_and_survive_restart() {
    let mut daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");

    // On connect: one board (board-0), active, plus its restore.
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0"]);
    assert_eq!(active, "board-0");
    assert_eq!(recv_restore(&mut app).0.as_deref(), Some("board-0"));

    // Lay out board-0: a doc opened on it + a term tile + a viewport.
    let d0 = write_doc(&daemon.dir.join("b0/a.md"), "a\n");
    cli_open(&daemon.sock, &d0);
    let vp0 = BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 };
    app.send(&Msg::Layout {
        dock: vec![d0.clone()],
        tiles: vec![term_tile("t0", 80.0), doc_tile(&d0)],
        board: Some(vp0.clone()),
        board_id: Some("board-0".into()),
    });

    // Create board-1 → it becomes active and restores fresh (one default term
    // tile, no docs).
    app.send(&Msg::BoardCreate);
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
    let (bid, docs, tiles, _) = recv_restore(&mut app);
    assert_eq!(bid.as_deref(), Some("board-1"));
    assert!(docs.is_empty(), "a fresh board has no docs");
    assert_eq!(tiles.len(), 1, "a fresh board carries one default terminal tile");
    assert_eq!(tiles[0].kind, "term");

    // Spawn a long-lived terminal owned by board-1 (records term -> board).
    app.send(&Msg::SpawnTerm {
        term_id: "t1".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/cat".into()]),
        board_id: Some("board-1".into()),
    });

    // Lay out board-1: its own doc (opened while board-1 is active) + term tile.
    let d1 = write_doc(&daemon.dir.join("b1/x.md"), "x\n");
    cli_open(&daemon.sock, &d1);
    let vp1 = BoardViewport { zoom: 1.0, cx: 0.0, cy: 0.0 };
    app.send(&Msg::Layout {
        dock: vec![d1.clone()],
        tiles: vec![term_tile("t1", 120.0), doc_tile(&d1)],
        board: Some(vp1.clone()),
        board_id: Some("board-1".into()),
    });

    // Switch to board-0: its own doc/tiles/viewport come back.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    assert_eq!(recv_board_list(&mut app).1, "board-0");
    let (bid, docs, tiles, board) = recv_restore(&mut app);
    assert_eq!(bid.as_deref(), Some("board-0"));
    assert_eq!(doc_paths(&docs), vec![d0.as_str()]);
    assert_eq!(tiles.len(), 2);
    assert_eq!(board, Some(vp0.clone()));

    // Provenance routing: while board-0 is active, open a doc attributed to the
    // term that lives on board-1 — it must land on board-1, not the active one.
    let d1b = write_doc(&daemon.dir.join("b1/y.md"), "y\n");
    app.send(&Msg::Open { path: d1b.clone(), term_id: Some("t1".into()), board_id: None });
    // Consume the doc_opened ack-push so it doesn't bleed into later reads.
    app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));

    // board-0 must NOT have gained the routed doc.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    recv_board_list(&mut app);
    assert_eq!(doc_paths(&recv_restore(&mut app).1), vec![d0.as_str()], "routed doc must not touch board-0");

    // board-1 has both its own doc and the routed doc.
    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    recv_board_list(&mut app);
    let (_, docs, _, board) = recv_restore(&mut app);
    let mut paths = doc_paths(&docs);
    paths.sort();
    let mut want = vec![d1.as_str(), d1b.as_str()];
    want.sort();
    assert_eq!(paths, want, "board-1 owns its doc + the routed doc");
    assert_eq!(board, Some(vp1.clone()));

    // Land on board-0 so the persisted active is deterministic, then restart.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // Wait for the full state (both boards, board-1's two docs, active board-0)
    // to hit disk before the SIGKILL restart.
    wait_for_state(&daemon.state_file(), "two boards persisted with active board-0", |v| {
        let boards = v["boards"].as_array();
        boards.is_some_and(|b| {
            b.len() == 2
                && b[0]["board_id"] == serde_json::json!("board-0")
                && b[1]["board_id"] == serde_json::json!("board-1")
                && b[1]["docs"].as_array().is_some_and(|d| d.len() == 2)
        }) && v["active"] == serde_json::json!("board-0")
    });
    drop(app);
    daemon.restart();

    // After a cold restart: both boards persist, active is board-0, and each
    // board reproduces its own docs/tiles/viewport independently.
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let (boards, active) = recv_board_list(&mut app2);
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-0");
    let (bid, docs, _, board) = recv_restore(&mut app2);
    assert_eq!(bid.as_deref(), Some("board-0"));
    assert_eq!(doc_paths(&docs), vec![d0.as_str()]);
    assert_eq!(board, Some(vp0));

    app2.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    recv_board_list(&mut app2);
    let (bid, docs, tiles, board) = recv_restore(&mut app2);
    assert_eq!(bid.as_deref(), Some("board-1"));
    let mut paths = doc_paths(&docs);
    paths.sort();
    assert_eq!(paths, want, "board-1 docs survive the restart");
    assert_eq!(board, Some(vp1));
    assert!(
        tiles.iter().any(|t| t.kind == "term" && t.term_id.as_deref() == Some("t1")),
        "board-1's term tile survives the restart"
    );
}

// A board_switch to an unknown board is a no-op (no crash, no reply) — the
// daemon stays responsive.
#[test]
fn board_switch_to_unknown_is_noop() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    app.send(&Msg::BoardSwitch { board_id: "board-404".into() });
    // The daemon ignores it; a subsequent create still works and replies.
    app.send(&Msg::BoardCreate);
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
}

// P5.4: deleting the active board kills its ptys (the killed term's pump pushes
// Exit) and re-pushes board_list (the deleted board gone, active fixed to a
// survivor) + the new active board's restore. Deleting the last board is refused.
#[test]
fn board_delete_kills_terms_fixes_active_and_refuses_last() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // Refusing the last board is a no-op: a following create still works (proving
    // the daemon stayed responsive AND board-0 was never removed).
    app.send(&Msg::BoardDelete { board_id: "board-0".into() });
    app.send(&Msg::BoardCreate);
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"], "last-board delete was refused");
    assert_eq!(active, "board-1");
    recv_restore(&mut app);

    // Spawn a long-lived shell on the active board-1 and confirm it is alive.
    app.send(&Msg::SpawnTerm {
        term_id: "tdel".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/cat".into()]),
        board_id: Some("board-1".into()),
    });
    app.send(&Msg::Input { term_id: "tdel".into(), bytes: b"alive\n".to_vec() });
    app.recv_until("live output", |m| {
        matches!(m, Msg::Output { term_id, bytes }
            if term_id.as_str() == "tdel" && common::contains(bytes, b"alive"))
    });

    // Delete the ACTIVE board-1: the daemon kills tdel and fixes active → board-0.
    app.send(&Msg::BoardDelete { board_id: "board-1".into() });

    // Both an Exit for the killed term AND a board_list listing only board-0
    // (active board-0) must arrive; their relative order is unspecified (the
    // killed pump's exit push races the delete arm's board_list over one tx).
    let mut saw_exit = false;
    let mut saw_final_list = false;
    let deadline = Instant::now() + LONG;
    while !(saw_exit && saw_final_list) {
        match app.recv(deadline, "post-delete frames") {
            Msg::Exit { term_id, .. } if term_id == "tdel" => saw_exit = true,
            Msg::BoardList { boards, active }
                if board_ids(&boards) == vec!["board-0"] && active == "board-0" =>
            {
                saw_final_list = true
            }
            _ => {}
        }
    }
    assert!(saw_exit, "the killed term's pump pushed Exit");
    assert!(saw_final_list, "board_list dropped board-1 and fixed active to board-0");
}

// P5.4: rename sets a board's display name, an empty name clears it back to the
// slug, and an unknown id is a silent no-op (no board_list pushed).
#[test]
fn board_rename_sets_clears_and_ignores_unknown() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // Rename board-0 → "infra": the re-pushed board_list carries the new name.
    app.send(&Msg::BoardRename { board_id: "board-0".into(), name: "infra".into() });
    let (boards, _) = recv_board_list(&mut app);
    assert_eq!(
        boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.name.as_deref()),
        Some("infra")
    );

    // An empty name clears it back to None (the slug fallback).
    app.send(&Msg::BoardRename { board_id: "board-0".into(), name: String::new() });
    let (boards, _) = recv_board_list(&mut app);
    assert_eq!(boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.name.clone()), None);

    // An unknown id pushes NOTHING; a following create still replies (daemon is
    // responsive, and the create's board_list is what we read — not a stray one).
    app.send(&Msg::BoardRename { board_id: "board-404".into(), name: "x".into() });
    app.send(&Msg::BoardCreate);
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
}

// P5.4: deleting a NON-active board leaves the active board untouched, drops the
// board from board_list, and still re-sends the (unchanged) active board's restore.
#[test]
fn board_delete_non_active_keeps_active() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // Create board-1 (active), then switch back so board-0 is active again.
    app.send(&Msg::BoardCreate);
    assert_eq!(recv_board_list(&mut app).1, "board-1");
    recv_restore(&mut app);
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    assert_eq!(recv_board_list(&mut app).1, "board-0");
    recv_restore(&mut app);

    // Delete the NON-active board-1.
    app.send(&Msg::BoardDelete { board_id: "board-1".into() });
    let (boards, active) = recv_board_list(&mut app);
    assert_eq!(board_ids(&boards), vec!["board-0"]);
    assert_eq!(active, "board-0", "a non-active delete doesn't switch the active board");
    // The arm still re-sends the (unchanged) active board's restore.
    assert_eq!(recv_restore(&mut app).0.as_deref(), Some("board-0"));
}

// P5.1/P5: a normal term exit re-pushes board_list with that board's running
// count recomputed (the load-bearing path behind the switcher's honest liveness).
#[test]
fn term_exit_recomputes_board_running_count() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // A long-lived shell keeps board-0's count at >=1 across the short-lived exit.
    app.send(&Msg::SpawnTerm {
        term_id: "tlong".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/cat".into()]),
        board_id: None,
    });
    // A short-lived shell that exits on its own.
    app.send(&Msg::SpawnTerm {
        term_id: "techo".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/echo".into(), "hi".into()]),
        board_id: None,
    });

    // When techo exits, the next (re-pushed) board_list reports board-0 running
    // Some(1) — the surviving tlong, with the exited techo correctly excluded.
    app.recv_until("techo exit", |m| {
        matches!(m, Msg::Exit { term_id, .. } if term_id.as_str() == "techo")
    });
    let list = app.recv_until("board_list after exit", |m| matches!(m, Msg::BoardList { .. }));
    let Msg::BoardList { boards, .. } = list else { unreachable!() };
    assert_eq!(
        boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.running),
        Some(1),
        "the exit re-push recomputes the running count (1 surviving shell, not 0 or 2)"
    );
}

// P5: an app disconnect leaves the board's shells running; a reconnecting app's
// restore advertises the board's live term_ids and replays their scrollback, so
// the app re-binds to the running shell instead of cold-spawning a fresh one.
#[test]
fn reconnect_rebinds_live_terms_and_replays_scrollback() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_board_list(&mut app);
    recv_restore(&mut app);

    // Spawn a long-lived shell on board-0 (cat echoes its stdin) and drive a
    // marker into it; the daemon dispatches SpawnTerm fully (registering the pty)
    // before the following Input, so there is no spawn/input race.
    app.send(&Msg::SpawnTerm {
        term_id: "t0".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/cat".into()]),
        board_id: None,
    });
    app.send(&Msg::Input { term_id: "t0".into(), bytes: b"scrollmark\n".to_vec() });
    app.recv_until("live output with marker", |m| {
        matches!(m, Msg::Output { term_id, bytes }
            if term_id.as_str() == "t0" && common::contains(bytes, b"scrollmark"))
    });

    // Disconnect; the shell must keep running daemon-side (no respawn on reconnect).
    drop(app);

    // Reconnect: the active board's restore lists t0 as live and its scrollback
    // replays, so the app re-binds rather than respawns.
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let (boards, _) = recv_board_list(&mut app2);
    assert_eq!(
        boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.running),
        Some(1),
        "board_list reports the surviving shell as running"
    );
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { live_terms, .. } = restore else { unreachable!() };
    assert!(
        live_terms.contains(&"t0".to_string()),
        "reconnect restore lists the live term, got {live_terms:?}"
    );
    app2.recv_until("replayed scrollback", |m| {
        matches!(m, Msg::Output { term_id, bytes }
            if term_id.as_str() == "t0" && common::contains(bytes, b"scrollmark"))
    });
}
