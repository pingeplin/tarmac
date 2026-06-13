// End-to-end M1 tests: doc states (repo, read, recency), layout snapshots,
// and durable state across a daemon restart. Harness lives in common/.

mod common;

use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon};
use tarmac_protocol::{BoardViewport, Msg, Tile, repo_color_index};

fn write_doc(path: &Path, content: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

// Geometry-less tiles (M1 shape): the v4 x/y/w/h/z (+ Phase 3 loose/shelf)
// keys default to None.
fn term_tile() -> Tile {
    Tile {
        kind: "term".into(),
        path: None,
        x: None,
        y: None,
        w: None,
        h: None,
        z: None,
        loose: None,
        shelf: None,
    }
}

fn doc_tile(path: &str) -> Tile {
    Tile { kind: "doc".into(), path: Some(path.into()), ..term_tile() }
}

fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
}

fn recv_doc_opened(app: &mut Conn) -> tarmac_protocol::DocEntry {
    let msg = app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));
    let Msg::DocOpened(entry) = msg else { unreachable!() };
    entry
}

fn recv_restore(app: &mut Conn) -> (Vec<tarmac_protocol::DocEntry>, Vec<Tile>) {
    let msg = app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs, tiles, .. } = msg else { unreachable!() };
    (docs, tiles)
}

// Persistence is debounced; poll the state file until it reflects the
// expected facts before killing the daemon.
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

#[test]
fn open_carries_repo_read_and_recency() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_restore(&mut app);

    // --- doc inside a repo marked by a .git directory ---
    let repo_dir = daemon.dir.join("payments-api");
    std::fs::create_dir_all(repo_dir.join(".git")).unwrap();
    let in_repo = write_doc(&repo_dir.join("docs/handoff.md"), "# handoff\n");
    let repo_root = std::fs::canonicalize(&repo_dir).unwrap().to_string_lossy().into_owned();

    cli_open(&daemon.sock, &in_repo);
    let entry = recv_doc_opened(&mut app);
    assert_eq!(entry.path, in_repo);
    assert_eq!(entry.via, "cli");
    assert_eq!(entry.repo.as_deref(), Some("payments-api"));
    assert_eq!(entry.repo_root.as_deref(), Some(repo_root.as_str()));
    assert_eq!(entry.repo_color, Some(repo_color_index("payments-api")));
    assert_eq!(entry.repo_color, Some(3)); // pinned reference value, protocol.md
    assert!(!entry.read, "cli open must register unread");
    assert!(entry.last_opened_ms.unwrap_or(0) > 0, "M1 daemons always send last_opened_ms");
    assert_eq!(entry.last_changed_ms, None);

    // --- repo marked by a gitfile (worktree/submodule) ---
    let wt_dir = daemon.dir.join("wt");
    std::fs::create_dir_all(&wt_dir).unwrap();
    std::fs::write(wt_dir.join(".git"), "gitdir: /elsewhere/wt\n").unwrap();
    let in_wt = write_doc(&wt_dir.join("note.md"), "wt\n");

    cli_open(&daemon.sock, &in_wt);
    let entry = recv_doc_opened(&mut app);
    assert_eq!(entry.repo.as_deref(), Some("wt"));
    assert_eq!(entry.repo_color, Some(repo_color_index("wt")));

    // --- doc outside any repo: repo fields nil ---
    let stray = write_doc(&daemon.dir.join("plain/readme.md"), "hi\n");
    cli_open(&daemon.sock, &stray);
    let entry = recv_doc_opened(&mut app);
    assert_eq!(entry.repo, None);
    assert_eq!(entry.repo_root, None);
    assert_eq!(entry.repo_color, None);

    // --- user open of a new doc never marks it unread ---
    let user_doc = write_doc(&daemon.dir.join("plain/mine.md"), "me\n");
    app.send(&Msg::Open { path: user_doc.clone(), term_id: None });
    let entry = recv_doc_opened(&mut app);
    assert_eq!(entry.via, "user");
    assert!(entry.read, "user opens never clear read");
}

#[test]
fn doc_read_flips_flag_and_shows_in_fresh_restore() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_restore(&mut app);

    let a = write_doc(&daemon.dir.join("a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    assert!(!recv_doc_opened(&mut app).read);

    // Unknown path: ignored, no error frame; then the real one, twice
    // (idempotent). A trailing user open sequences past the fire-and-forget
    // frames: its doc_opened proves they were dispatched.
    app.send(&Msg::DocRead { path: "/no/such/doc.md".into() });
    app.send(&Msg::DocRead { path: a.clone() });
    app.send(&Msg::DocRead { path: a.clone() });
    let b = write_doc(&daemon.dir.join("b.md"), "b\n");
    app.send(&Msg::Open { path: b.clone(), term_id: None });
    let entry = recv_doc_opened(&mut app);
    assert_eq!(entry.path, b);

    // Fresh app connection: read survives, dock order is insertion order.
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let (docs, tiles) = recv_restore(&mut app2);
    assert_eq!(docs.len(), 2);
    assert_eq!(docs[0].path, a);
    assert!(docs[0].read, "doc_read must persist into restore");
    assert_eq!(docs[1].path, b);
    assert_eq!(tiles, vec![term_tile()]);

    // cli re-open re-marks unread and never moves the dock slot.
    cli_open(&daemon.sock, &a);
    let entry = recv_doc_opened(&mut app2);
    assert_eq!(entry.path, a);
    assert!(!entry.read, "cli re-open must re-mark unread");

    let mut app3 = Conn::hello(&daemon.sock, "app");
    let (docs, _) = recv_restore(&mut app3);
    assert_eq!(docs[0].path, a, "re-open must not move the dock slot");
    assert!(!docs[0].read);
}

#[test]
fn layout_and_state_survive_daemon_restart() {
    let mut daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_restore(&mut app);

    let repo_dir = daemon.dir.join("search-svc");
    std::fs::create_dir_all(repo_dir.join(".git")).unwrap();
    let a = write_doc(&repo_dir.join("a.md"), "a\n");
    let b = write_doc(&repo_dir.join("b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    recv_doc_opened(&mut app);
    cli_open(&daemon.sock, &b);
    recv_doc_opened(&mut app);

    app.send(&Msg::DocRead { path: a.clone() });
    // Snapshot puts b first and omits a (must append after, per merge rules);
    // unknown paths and unknown tile kinds are dropped.
    app.send(&Msg::Layout {
        dock: vec![b.clone(), "/not/registered.md".into()],
        tiles: vec![
            term_tile(),
            doc_tile(&b),
            Tile { kind: "split".into(), ..term_tile() },
            doc_tile("/not/registered.md"),
        ],
        board: None,
    });

    // A file change before the restart: last_changed_ms must survive too.
    std::thread::sleep(Duration::from_millis(300)); // let the watch settle
    let mut f = std::fs::OpenOptions::new().append(true).open(&a).unwrap();
    f.write_all(b"\nmore\n").unwrap();
    f.sync_all().unwrap();
    drop(f);
    app.recv_until("file_event", |m| matches!(m, Msg::FileEvent { path, .. } if *path == a));

    wait_for_state(&daemon.state_file(), "merged layout + read + change", |v| {
        let docs = v["docs"].as_array();
        docs.is_some_and(|d| {
            d.len() == 2
                && d[0]["path"] == serde_json::json!(b)
                && d[1]["path"] == serde_json::json!(a)
                && d[1]["read"] == serde_json::json!(true)
                && d[1]["last_changed_ms"].is_u64()
        }) && v["tiles"].as_array().is_some_and(|t| t.len() == 2)
    });

    let mut app2 = Conn::hello(&daemon.sock, "app");
    let before = recv_restore(&mut app2);
    drop(app2);
    drop(app);

    daemon.restart();

    let mut app3 = Conn::hello(&daemon.sock, "app");
    let after = recv_restore(&mut app3);
    assert_eq!(before, after, "restore after restart must be indistinguishable");

    let (docs, tiles) = after;
    assert_eq!(docs.len(), 2);
    assert_eq!(docs[0].path, b);
    assert!(!docs[0].read);
    assert_eq!(docs[1].path, a);
    assert!(docs[1].read);
    assert!(docs[1].last_changed_ms.is_some());
    assert!(docs[1].last_opened_ms.is_some());
    assert_eq!(docs[1].repo.as_deref(), Some("search-svc"));
    assert_eq!(docs[1].repo_color, Some(repo_color_index("search-svc")));
    assert_eq!(tiles, vec![term_tile(), doc_tile(&b)]);

    // Watches were re-established at load: a change to a restored doc emits.
    std::thread::sleep(Duration::from_millis(300)); // let the watch settle
    let mut f = std::fs::OpenOptions::new().append(true).open(&b).unwrap();
    f.write_all(b"\nagain\n").unwrap();
    f.sync_all().unwrap();
    drop(f);
    app3.recv_until("file_event after restart", |m| {
        matches!(m, Msg::FileEvent { path, .. } if *path == b)
    });
}

// v4 Phase 2 (additive): the board viewport + per-tile world frame round-trip
// through a layout snapshot, persist to disk, and reproduce after a restart.
#[test]
fn board_geometry_and_viewport_survive_daemon_restart() {
    let mut daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_restore(&mut app);

    let repo_dir = daemon.dir.join("board");
    std::fs::create_dir_all(repo_dir.join(".git")).unwrap();
    let a = write_doc(&repo_dir.join("a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    recv_doc_opened(&mut app);

    let board = BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 };
    let term = Tile { kind: "term".into(), x: Some(92.0), y: Some(108.0), w: Some(470.0), h: Some(330.0), z: Some(0), path: None, loose: None, shelf: None };
    let doc = Tile { kind: "doc".into(), path: Some(a.clone()), x: Some(648.0), y: Some(140.0), w: Some(392.0), h: Some(310.0), z: Some(1), loose: None, shelf: None };
    app.send(&Msg::Layout {
        dock: vec![a.clone()],
        tiles: vec![term.clone(), doc.clone()],
        board: Some(board.clone()),
    });

    wait_for_state(&daemon.state_file(), "board + tile geometry", |v| {
        let tiles = v["tiles"].as_array();
        let geom_ok = tiles.is_some_and(|t| {
            t.len() == 2
                && t[1]["x"].as_f64() == Some(648.0)
                && t[1]["w"].as_f64() == Some(392.0)
                && t[1]["z"].as_i64() == Some(1)
        });
        let board_ok = v["board"]["zoom"].as_f64() == Some(0.82)
            && v["board"]["cx"].as_f64() == Some(640.0);
        geom_ok && board_ok
    });

    drop(app);

    daemon.restart();

    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { tiles, board: restored_board, .. } = restore else { unreachable!() };
    assert_eq!(tiles, vec![term, doc], "tile world frames must reproduce after restart");
    assert_eq!(restored_board, Some(board), "board viewport must reproduce after restart");
}

// v4 Phase 3 (additive): a shelf-parked, gravity-detached doc tile survives a
// restart (sent via layout, reappears in restore); a doc's provenance term_id
// is preserved through the restart.
#[test]
fn shelf_loose_and_term_id_survive_daemon_restart() {
    let mut daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    recv_restore(&mut app);

    let repo_dir = daemon.dir.join("shelf");
    std::fs::create_dir_all(repo_dir.join(".git")).unwrap();
    let a = write_doc(&repo_dir.join("a.md"), "a\n");

    // Open the doc with a calling term_id (provenance owner).
    app.send(&Msg::Open { path: a.clone(), term_id: Some("term-7".into()) });
    let opened = recv_doc_opened(&mut app);
    assert_eq!(opened.term_id.as_deref(), Some("term-7"), "open must carry the term_id");

    // Park the doc on the shelf: kind "doc", shelf:true, loose:true, no geometry.
    let shelf_tile = Tile {
        kind: "doc".into(),
        path: Some(a.clone()),
        x: None,
        y: None,
        w: None,
        h: None,
        z: None,
        loose: Some(true),
        shelf: Some(true),
    };
    app.send(&Msg::Layout {
        dock: vec![a.clone()],
        tiles: vec![term_tile(), shelf_tile.clone()],
        board: None,
    });

    wait_for_state(&daemon.state_file(), "shelf tile + term_id", |v| {
        let tile_ok = v["tiles"].as_array().is_some_and(|t| {
            t.iter().any(|tile| {
                tile["kind"] == serde_json::json!("doc")
                    && tile["shelf"] == serde_json::json!(true)
                    && tile["loose"] == serde_json::json!(true)
                    && tile["x"].is_null()
            })
        });
        let term_ok = v["docs"]
            .as_array()
            .is_some_and(|d| d.iter().any(|doc| doc["term_id"] == serde_json::json!("term-7")));
        tile_ok && term_ok
    });

    drop(app);
    daemon.restart();

    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs, tiles, .. } = restore else { unreachable!() };

    assert!(
        tiles.contains(&shelf_tile),
        "shelf doc tile (shelf:true, loose:true, no geometry) must reproduce after restart"
    );
    assert_eq!(
        docs.iter().find(|d| d.path == a).and_then(|d| d.term_id.as_deref()),
        Some("term-7"),
        "doc provenance term_id must survive a restart"
    );
}
