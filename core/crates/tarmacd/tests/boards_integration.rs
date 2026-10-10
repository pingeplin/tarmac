// End-to-end boards ("strips = boards"): board_list on connect, board_create /
// board_switch, per-board layout that persists independently across a daemon
// restart, and `tarmac open` provenance routing the doc to the calling term's board.

mod common;

use std::time::{Duration, Instant};

use common::{LONG, Spawn, TestDaemon, cli_open, mtime_ms, settle, touch, write_doc};
use tarmac_protocol::{BoardMeta, BoardViewport, DocEntry, Msg, Tile};

fn term_tile(term_id: &str, x: f64) -> Tile {
    Tile {
        kind: "term".into(),
        x: Some(x),
        y: Some(80.0),
        w: Some(470.0),
        h: Some(330.0),
        z: Some(0),
        term_id: Some(term_id.into()),
        ..Default::default()
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
        ..Default::default()
    }
}

fn board_ids(boards: &[BoardMeta]) -> Vec<&str> {
    boards.iter().map(|b| b.board_id.as_str()).collect()
}

fn doc_paths(docs: &[DocEntry]) -> Vec<&str> {
    docs.iter().map(|d| d.path.as_str()).collect()
}

fn running(boards: &[BoardMeta], board_id: &str) -> Option<u32> {
    boards.iter().find(|b| b.board_id == board_id).and_then(|b| b.running)
}

// Two boards each keep their own docs/tiles/viewport across a daemon restart,
// board_create/switch behave, and `tarmac open` from a term on board-1 lands the
// doc on board-1 even when board-0 is active.
#[test]
fn boards_create_switch_route_and_survive_restart() {
    let mut daemon = TestDaemon::start();
    let mut app = daemon.connect_app();

    // On connect: one board (board-0), active, plus its restore.
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0"]);
    assert_eq!(active, "board-0");
    assert_eq!(app.recv_restore().board_id.as_deref(), Some("board-0"));

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
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
    let fresh = app.recv_restore();
    assert_eq!(fresh.board_id.as_deref(), Some("board-1"));
    assert!(fresh.docs.is_empty(), "a fresh board has no docs");
    assert_eq!(fresh.tiles.len(), 1, "a fresh board carries one default terminal tile");
    assert_eq!(fresh.tiles[0].kind, "term");

    // Spawn a long-lived terminal owned by board-1 (records term -> board).
    app.spawn_term_with("t1", &["/bin/cat"], Spawn::on_board("board-1"));

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
    assert_eq!(app.recv_board_list().1, "board-0");
    let back = app.recv_restore();
    assert_eq!(back.board_id.as_deref(), Some("board-0"));
    assert_eq!(doc_paths(&back.docs), vec![d0.as_str()]);
    assert_eq!(back.tiles.len(), 2);
    assert_eq!(back.board, Some(vp0.clone()));

    // Provenance routing: while board-0 is active, open a doc attributed to the
    // term that lives on board-1 — it must land on board-1, not the active one.
    let d1b = write_doc(&daemon.dir.join("b1/y.md"), "y\n");
    app.send(&Msg::Open { path: d1b.clone(), term_id: Some("t1".into()), board_id: None });
    // Consume the doc_opened ack-push so it doesn't bleed into later reads.
    app.recv_doc_opened();

    // board-0 must NOT have gained the routed doc.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_board_list();
    assert_eq!(doc_paths(&app.recv_restore().docs), vec![d0.as_str()], "routed doc must not touch board-0");

    // board-1 has both its own doc and the routed doc.
    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    app.recv_board_list();
    let board1 = app.recv_restore();
    let mut paths = doc_paths(&board1.docs);
    paths.sort();
    let mut want = vec![d1.as_str(), d1b.as_str()];
    want.sort();
    assert_eq!(paths, want, "board-1 owns its doc + the routed doc");
    assert_eq!(board1.board, Some(vp1.clone()));

    // Land on board-0 so the persisted active is deterministic, then restart.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.drain_board();

    // Wait for the full state (both boards, board-1's two docs, active board-0)
    // to hit disk before the SIGKILL restart.
    daemon.wait_for_state("two boards persisted with active board-0", |v| {
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
    let mut app2 = daemon.connect_app();
    let (boards, active) = app2.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-0");
    let restored0 = app2.recv_restore();
    assert_eq!(restored0.board_id.as_deref(), Some("board-0"));
    assert_eq!(doc_paths(&restored0.docs), vec![d0.as_str()]);
    assert_eq!(restored0.board, Some(vp0));

    app2.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    app2.recv_board_list();
    let restored1 = app2.recv_restore();
    assert_eq!(restored1.board_id.as_deref(), Some("board-1"));
    let mut paths = doc_paths(&restored1.docs);
    paths.sort();
    assert_eq!(paths, want, "board-1 docs survive the restart");
    assert_eq!(restored1.board, Some(vp1));
    assert!(
        restored1.tiles.iter().any(|t| t.kind == "term" && t.term_id.as_deref() == Some("t1")),
        "board-1's term tile survives the restart"
    );
}

// A board_switch to an unknown board is a no-op (no crash, no reply) — the
// daemon stays responsive.
#[test]
fn board_switch_to_unknown_is_noop() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.send(&Msg::BoardSwitch { board_id: "board-404".into() });
    // The daemon ignores it; a subsequent create still works and replies.
    app.send(&Msg::BoardCreate);
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
}

// Deleting the active board kills its ptys (the killed term's pump pushes Exit)
// and re-pushes board_list (the deleted board gone, active fixed to a survivor) +
// the new active board's restore. Deleting the last board is refused.
#[test]
fn board_delete_kills_terms_fixes_active_and_refuses_last() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // Refusing the last board is a no-op: a following create still works (proving
    // the daemon stayed responsive AND board-0 was never removed).
    app.send(&Msg::BoardDelete { board_id: "board-0".into() });
    app.send(&Msg::BoardCreate);
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"], "last-board delete was refused");
    assert_eq!(active, "board-1");
    app.recv_restore();

    // Spawn a long-lived shell on the active board-1 and confirm it is alive.
    app.spawn_term_with("tdel", &["/bin/cat"], Spawn::on_board("board-1"));
    app.echo_marker("tdel", "alive");

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

// Rename sets a board's display name, an empty name clears it back to the slug,
// and an unknown id is a silent no-op (no board_list pushed).
#[test]
fn board_rename_sets_clears_and_ignores_unknown() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // Rename board-0 → "infra": the re-pushed board_list carries the new name.
    app.send(&Msg::BoardRename { board_id: "board-0".into(), name: "infra".into() });
    let (boards, _) = app.recv_board_list();
    assert_eq!(
        boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.name.as_deref()),
        Some("infra")
    );

    // An empty name clears it back to None (the slug fallback).
    app.send(&Msg::BoardRename { board_id: "board-0".into(), name: String::new() });
    let (boards, _) = app.recv_board_list();
    assert_eq!(boards.iter().find(|b| b.board_id == "board-0").and_then(|b| b.name.clone()), None);

    // An unknown id pushes NOTHING; a following create still replies (daemon is
    // responsive, and the create's board_list is what we read — not a stray one).
    app.send(&Msg::BoardRename { board_id: "board-404".into(), name: "x".into() });
    app.send(&Msg::BoardCreate);
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0", "board-1"]);
    assert_eq!(active, "board-1");
}

// Deleting a NON-active board leaves the active board untouched, drops the
// board from board_list, and still re-sends the (unchanged) active board's restore.
#[test]
fn board_delete_non_active_keeps_active() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // Create board-1 (active), then switch back so board-0 is active again.
    app.send(&Msg::BoardCreate);
    assert_eq!(app.recv_board_list().1, "board-1");
    app.recv_restore();
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    assert_eq!(app.recv_board_list().1, "board-0");
    app.recv_restore();

    app.send(&Msg::BoardDelete { board_id: "board-1".into() });
    let (boards, active) = app.recv_board_list();
    assert_eq!(board_ids(&boards), vec!["board-0"]);
    assert_eq!(active, "board-0", "a non-active delete doesn't switch the active board");
    // The arm still re-sends the (unchanged) active board's restore.
    assert_eq!(app.recv_restore().board_id.as_deref(), Some("board-0"));
}

// A normal term exit re-pushes board_list with that board's running count
// recomputed (the load-bearing path behind the switcher's honest liveness).
#[test]
fn term_exit_recomputes_board_running_count() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // A long-lived shell keeps board-0's count at >=1 across the short-lived exit.
    app.spawn_term("tlong", &["/bin/cat"]);
    // A short-lived shell that exits on its own.
    app.spawn_term("techo", &["/bin/echo", "hi"]);

    // When techo exits, the next (re-pushed) board_list reports board-0 running
    // Some(1) — the surviving tlong, with the exited techo correctly excluded.
    app.recv_until("techo exit", |m| {
        matches!(m, Msg::Exit { term_id, .. } if term_id.as_str() == "techo")
    });
    let (boards, _) = app.recv_board_list();
    assert_eq!(
        running(&boards, "board-0"),
        Some(1),
        "the exit re-push recomputes the running count (1 surviving shell, not 0 or 2)"
    );
}

// An app disconnect leaves the board's shells running; a reconnecting app's
// restore advertises the board's live term_ids and replays their scrollback, so
// the app re-binds to the running shell instead of cold-spawning a fresh one.
#[test]
fn reconnect_rebinds_live_terms_and_replays_scrollback() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // Spawn a long-lived shell on board-0 (cat echoes its stdin) and drive a
    // marker into it; the daemon dispatches SpawnTerm fully (registering the pty)
    // before the following Input, so there is no spawn/input race.
    app.spawn_term("t0", &["/bin/cat"]);
    app.echo_marker("t0", "scrollmark");

    // Disconnect; the shell must keep running daemon-side (no respawn on reconnect).
    drop(app);

    // Reconnect: the active board's restore lists t0 as live and its scrollback
    // replays, so the app re-binds rather than respawns.
    let mut app2 = daemon.connect_app();
    let (boards, _) = app2.recv_board_list();
    assert_eq!(
        running(&boards, "board-0"),
        Some(1),
        "board_list reports the surviving shell as running"
    );
    let live_terms = app2.recv_restore().live_terms;
    assert!(
        live_terms.contains(&"t0".to_string()),
        "reconnect restore lists the live term, got {live_terms:?}"
    );
    app2.recv_output_containing("t0", "scrollmark");
}

// Dropping the deleted board's watches restarts the FSEvents stream once for
// each directory, and the stream reports nothing from those gaps (#249). A doc
// of a board that is left changes in one: the daemon must still say so.
#[test]
fn board_delete_reports_a_change_made_while_it_dropped_the_watches() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let kept = write_doc(&daemon.dir.join("kept/x.md"), "x\n");
    cli_open(&daemon.sock, &kept);
    app.recv_doc_opened_for(&kept);

    app.send(&Msg::BoardCreate);
    app.recv_restore_for("board-1");
    for i in 0..100 {
        let doc = write_doc(&daemon.dir.join(format!("gone/{i}/b.md")), "b\n");
        cli_open(&daemon.sock, &doc);
        app.recv_doc_opened_for(&doc);
    }
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_restore_for("board-0");
    settle();

    // 100 directories take about 100 ms to drop; the edit is inside that time.
    app.send(&Msg::BoardDelete { board_id: "board-1".into() });
    std::thread::sleep(Duration::from_millis(20));
    touch(&kept);
    app.recv_file_event_since(&kept, mtime_ms(&kept));
}

// The delete itself schedules the save. The test first waits for the save of
// the create and lets the debounce pass, so no earlier save can drop the board.
#[test]
fn board_delete_persists() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let saved_boards = |v: &serde_json::Value| v["boards"].as_array().map_or(0, Vec::len);

    app.send(&Msg::BoardCreate);
    app.recv_restore_for("board-1");
    daemon.wait_for_state("board-1 saved", |v| saved_boards(v) == 2);
    settle();

    app.send(&Msg::BoardDelete { board_id: "board-1".into() });
    assert_eq!(board_ids(&app.recv_board_list().0), vec!["board-0"]);
    daemon.wait_for_state("board-1 gone from the saved state", |v| saved_boards(v) == 1);
}

