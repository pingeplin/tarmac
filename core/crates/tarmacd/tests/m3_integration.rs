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
    let Msg::Restore { board_id, docs, tiles, board } = msg else { unreachable!() };
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
