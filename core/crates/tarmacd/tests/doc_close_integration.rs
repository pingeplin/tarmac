// issue #34: `doc_close` removes a doc from the daemon registry, persists
// state.json, and unwatches the parent dir iff no sibling doc remains in it.
// An unknown path is a benign no-op; the handler is idempotent under repeat.
// Harness lives in common/.

mod common;

use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon, none_within};
use tarmac_protocol::Msg;

fn write_doc(path: &Path, content: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

fn cli_open(sock: &Path, path: &str) {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::Open { path: path.into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
}

fn drain_connect(app: &mut Conn) {
    app.recv_until("board_list", |m| matches!(m, Msg::BoardList { .. }));
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
}

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

// touch a file to trigger a file-system event and update mtime
fn touch(path: &str) {
    let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    f.write_all(b"\n").unwrap();
    f.sync_all().unwrap();
}

// DocClose removes path from Registry.docs + dock; state.json no longer
// carries the path; after a daemon restart the doc does not reappear in Restore.
#[test]
fn doc_close_removes_from_registry_and_persists() {
    let mut daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));

    app.send(&Msg::DocClose { path: a.clone() });

    // state.json must not contain the closed path.
    wait_for_state(&daemon.state_file(), "path absent", |v| {
        let docs = v["boards"][0]["docs"].as_array();
        docs.map(|d| d.iter().all(|e| e["path"] != serde_json::json!(a))).unwrap_or(true)
    });

    // After a restart the doc must not reappear in Restore.
    drop(app);
    daemon.restart();
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs, .. } = restore else { unreachable!() };
    assert!(
        docs.iter().all(|d| d.path != a),
        "closed doc must not reappear in Restore after daemon restart"
    );
}

// When a doc is the only entry in its parent dir, DocClose unwatches the dir
// and no further FileEvent is emitted for it. The live baseline (a FileEvent
// observed before the close) makes the post-close absence a genuine transition.
#[test]
fn doc_close_unwatches_dir_when_sole_occupant() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    let a = write_doc(&daemon.dir.join("sole/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));

    // Baseline: live file_event proves the dir is watched before the close.
    std::thread::sleep(Duration::from_millis(300));
    touch(&a);
    app.recv_until("file_event baseline", |m| {
        matches!(m, Msg::FileEvent { path, .. } if path == &a)
    });

    app.send(&Msg::DocClose { path: a.clone() });
    wait_for_state(&daemon.state_file(), "path absent after close", |v| {
        let docs = v["boards"][0]["docs"].as_array();
        docs.map(|d| d.iter().all(|e| e["path"] != serde_json::json!(a))).unwrap_or(true)
    });

    // Wait for any in-flight events to settle, then touch the closed path.
    std::thread::sleep(Duration::from_millis(300));
    touch(&a);

    // No FileEvent should arrive for the closed path; the doc is deregistered.
    // (The watch→unwatch transition on watched_dirs is verified by the unit
    // tests in state.rs.)
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| {
            matches!(m, Msg::FileEvent { path, .. } if path == &a)
        }),
        "FileEvent must not fire after the doc is deregistered"
    );
}

// When two docs share a parent dir, closing one keeps the dir watched for the
// survivor. Touching the survivor emits a FileEvent; touching the closed path does
// not (the path is gone from the registry so watch_loop skips it).
#[test]
fn doc_close_keeps_dir_watched_when_sibling_remains() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    let a = write_doc(&daemon.dir.join("shared/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("shared/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_until("doc_opened a", |m| matches!(m, Msg::DocOpened(e) if e.path == a));
    cli_open(&daemon.sock, &b);
    app.recv_until("doc_opened b", |m| matches!(m, Msg::DocOpened(e) if e.path == b));

    // Close doc A; B's dir must remain watched.
    app.send(&Msg::DocClose { path: a.clone() });
    wait_for_state(&daemon.state_file(), "a absent, b present", |v| {
        let docs = v["boards"][0]["docs"].as_array();
        docs.is_some_and(|d| {
            d.iter().all(|e| e["path"] != serde_json::json!(a))
                && d.iter().any(|e| e["path"] == serde_json::json!(b))
        })
    });

    std::thread::sleep(Duration::from_millis(300));

    // Survivor B still emits — the dir stays watched.
    touch(&b);
    app.recv_until("file_event for survivor b", |m| {
        matches!(m, Msg::FileEvent { path, .. } if path == &b)
    });

    // Touching closed A emits nothing — it is not in the registry.
    touch(&a);
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| {
            matches!(m, Msg::FileEvent { path, .. } if path == &a)
        }),
        "FileEvent must not fire for a path removed from the registry"
    );
}

// DocClose for an unknown path is a no-op. An unrelated open doc still
// appears in Registry/dock and its dir stays watched (the observable post-condition
// that rules out "the unknown close silently tore something else down").
#[test]
fn doc_close_unknown_path_is_noop() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    let a = write_doc(&daemon.dir.join("keep/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_until("doc_opened", |m| matches!(m, Msg::DocOpened(_)));

    // Close an unknown path.
    app.send(&Msg::DocClose { path: "/no/such/doc.md".into() });

    // A fresh restore from a new connection is the authoritative registry check.
    // app2 replaces app as the daemon's active connection; use app2 for all
    // subsequent reads (the daemon no longer sends to the old app connection).
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs, .. } = restore else { unreachable!() };
    assert!(
        docs.iter().any(|d| d.path == a),
        "unrelated doc must survive an unknown-path DocClose"
    );

    // Its dir must still be watched: touching it emits a FileEvent on app2.
    std::thread::sleep(Duration::from_millis(300));
    touch(&a);
    app2.recv_until("file_event still fires", |m| {
        matches!(m, Msg::FileEvent { path, .. } if path == &a)
    });
}

// A second DocClose for the same path (double-click / stale frontend) is a
// no-op — no panic, no second persist, no effect on other docs.
#[test]
fn doc_close_idempotent_on_repeat() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    drain_connect(&mut app);

    let a = write_doc(&daemon.dir.join("idem/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("other/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_until("doc_opened a", |m| matches!(m, Msg::DocOpened(e) if e.path == a));
    cli_open(&daemon.sock, &b);
    app.recv_until("doc_opened b", |m| matches!(m, Msg::DocOpened(e) if e.path == b));

    // First close.
    app.send(&Msg::DocClose { path: a.clone() });
    wait_for_state(&daemon.state_file(), "a removed (first)", |v| {
        let docs = v["boards"][0]["docs"].as_array();
        docs.map(|d| d.iter().all(|e| e["path"] != serde_json::json!(a))).unwrap_or(true)
    });

    // Second close — must be a benign no-op (both closes happen on `app`,
    // which is still the active connection at this point).
    app.send(&Msg::DocClose { path: a.clone() });

    // Connect app2 to get an authoritative restore; it replaces app as the
    // daemon's active connection so use app2 for all reads after this point.
    let mut app2 = Conn::hello(&daemon.sock, "app");
    let restore = app2.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));
    let Msg::Restore { docs, .. } = restore else { unreachable!() };
    assert!(
        docs.iter().any(|d| d.path == b),
        "unrelated doc b must survive a double DocClose for a"
    );
    assert!(
        docs.iter().all(|d| d.path != a),
        "closed doc a must remain absent after a second DocClose"
    );

    std::thread::sleep(Duration::from_millis(300));
    touch(&b);
    app2.recv_until("b watch survives double close", |m| {
        matches!(m, Msg::FileEvent { path, .. } if path == &b)
    });
}
