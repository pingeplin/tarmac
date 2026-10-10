// issue #34: `doc_close` removes a doc from the daemon registry, persists
// state.json, and unwatches the parent dir. Since #235 the dir stays watched while
// any board has a doc in it.
// An unknown path is a benign no-op; the handler is idempotent under repeat.

mod common;

use std::time::Duration;

use common::{TestDaemon, cli_open, has_doc, is_file_event_for, mtime_ms, none_within, settle, touch, write_doc};
use tarmac_protocol::Msg;

// DocClose removes path from Registry.docs + dock; state.json no longer
// carries the path; after a daemon restart the doc does not reappear in Restore.
#[test]
fn doc_close_removes_from_registry_and_persists() {
    let mut daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    app.send(&Msg::DocClose { path: a.clone() });

    daemon.wait_for_state("path absent", |v| !has_doc(v, 0, &a));

    // After a restart the doc must not reappear in Restore.
    drop(app);
    daemon.restart();
    let mut app2 = daemon.connect_app();
    let docs = app2.recv_restore().docs;
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
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("sole/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    // Baseline: live file_event proves the dir is watched before the close.
    settle();
    touch(&a);
    app.recv_file_event_for(&a);

    app.send(&Msg::DocClose { path: a.clone() });
    daemon.wait_for_state("path absent after close", |v| !has_doc(v, 0, &a));

    // Wait for any in-flight events to settle, then touch the closed path.
    settle();
    touch(&a);

    // No FileEvent should arrive for the closed path; the doc is deregistered.
    // (The watch→unwatch transition on watched_dirs is verified by the unit
    // tests in state.rs.)
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| is_file_event_for(m, &a)),
        "FileEvent must not fire after the doc is deregistered"
    );
}

// When two docs share a parent dir, closing one keeps the dir watched for the
// survivor. Touching the survivor emits a FileEvent; touching the closed path does
// not (the path is gone from the registry so watch_loop skips it).
#[test]
fn doc_close_keeps_dir_watched_when_sibling_remains() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("shared/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("shared/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened_for(&a);
    cli_open(&daemon.sock, &b);
    app.recv_doc_opened_for(&b);

    // Close doc A; B's dir must remain watched.
    app.send(&Msg::DocClose { path: a.clone() });
    daemon.wait_for_state("a absent, b present", |v| !has_doc(v, 0, &a) && has_doc(v, 0, &b));

    settle();

    // Survivor B still emits — the dir stays watched.
    touch(&b);
    app.recv_file_event_for(&b);

    // Touching closed A emits nothing — it is not in the registry.
    touch(&a);
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| is_file_event_for(m, &a)),
        "FileEvent must not fire for a path removed from the registry"
    );
}

// The watch set is one per daemon, not one per board. A board that closes its
// last doc in a directory must not take the watch from a doc that another board
// has there (#235).
//
// Each wait matches the mtime of its own touch. A path-only wait takes an older
// event for `a` (the replayed creation, or the first touch's event that arrives
// after the switch back), and the test then passes with no watch on the dir.
#[test]
fn doc_close_keeps_dir_watched_for_a_doc_on_another_board() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("shared/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("shared/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened_for(&a);
    settle();
    touch(&a);
    app.recv_file_event_since(&a, mtime_ms(&a));

    // The close and the switch go down one connection, so the daemon handles
    // them in this order.
    app.send(&Msg::BoardCreate);
    app.recv_restore_for("board-1");
    cli_open(&daemon.sock, &b);
    app.recv_doc_opened_for(&b);
    app.send(&Msg::DocClose { path: b.clone() });
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_restore_for("board-0");

    settle();
    touch(&a);
    app.recv_file_event_since(&a, mtime_ms(&a));
}

// DocClose for an unknown path is a no-op. An unrelated open doc still
// appears in Registry/dock and its dir stays watched (the observable post-condition
// that rules out "the unknown close silently tore something else down").
#[test]
fn doc_close_unknown_path_is_noop() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("keep/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    app.send(&Msg::DocClose { path: "/no/such/doc.md".into() });

    // A fresh restore from a new connection is the authoritative registry check.
    // app2 replaces app as the daemon's active connection; use app2 for all
    // subsequent reads (the daemon no longer sends to the old app connection).
    let mut app2 = daemon.connect_app();
    let docs = app2.recv_restore().docs;
    assert!(
        docs.iter().any(|d| d.path == a),
        "unrelated doc must survive an unknown-path DocClose"
    );

    // Its dir must still be watched: touching it emits a FileEvent on app2.
    settle();
    touch(&a);
    app2.recv_file_event_for(&a);
}

// A second DocClose for the same path (double-click / stale frontend) is a
// no-op — no panic, no second persist, no effect on other docs.
#[test]
fn doc_close_idempotent_on_repeat() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("idem/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("other/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened_for(&a);
    cli_open(&daemon.sock, &b);
    app.recv_doc_opened_for(&b);

    app.send(&Msg::DocClose { path: a.clone() });
    daemon.wait_for_state("a removed (first)", |v| !has_doc(v, 0, &a));

    // Second close — must be a benign no-op (both closes happen on `app`,
    // which is still the active connection at this point).
    app.send(&Msg::DocClose { path: a.clone() });

    // Connect app2 to get an authoritative restore; it replaces app as the
    // daemon's active connection so use app2 for all reads after this point.
    let mut app2 = daemon.connect_app();
    let docs = app2.recv_restore().docs;
    assert!(
        docs.iter().any(|d| d.path == b),
        "unrelated doc b must survive a double DocClose for a"
    );
    assert!(
        docs.iter().all(|d| d.path != a),
        "closed doc a must remain absent after a second DocClose"
    );

    settle();
    touch(&b);
    app2.recv_file_event_for(&b);
}
