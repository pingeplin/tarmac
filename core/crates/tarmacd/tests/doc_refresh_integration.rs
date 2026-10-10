// issue #89 / spec 2609.0001: `doc_refresh` re-stats a doc on demand and pushes the
// ordinary `file_event`, so a card can be refreshed without waiting for the notify
// watcher. It always pushes on a successful stat (changed mtime or not), records the
// mtime in the ACTIVE board's registry before pushing, and is a silent no-op for an
// unknown path, a background-board doc, or an unreadable file.

mod common;

use std::time::Duration;

use common::{
    Conn, TestDaemon, cli_open, doc_entry, dock_index, has_doc, is_file_event_for, mtime_ms, none_within, touch,
    write_doc,
};
use serde_json::json;
use tarmac_protocol::Msg;

// Settle the watcher after an open. FSEvents replays the file's own creation to the
// freshly-attached dir watch, so without this a test that edits and then waits for
// "the watcher's event" can consume the CREATE instead — leaving the edit's event
// queued to be mistaken for the refresh's. That is precisely the vacuity this suite
// is arranged to avoid, so every test that later attributes an event to the refresh
// settles first.
fn settle_watcher(app: &mut Conn, path: &str) {
    let _ = none_within(app, Duration::from_millis(800), |m| is_file_event_for(m, path));
}

// The refresh's own file_event. Fails loudly if a doc_opened or an err arrives
// instead — a refresh is not a re-open, and a no-op is silent, not an error.
fn recv_refresh_event(app: &mut Conn, path: &str) -> u64 {
    let msg = app.recv_until("file_event from doc_refresh", |m| match m {
        Msg::DocOpened(e) => panic!("doc_refresh must not re-open the doc (got doc_opened for {})", e.path),
        Msg::Err { msg } => panic!("doc_refresh must not send err, got: {msg}"),
        other => is_file_event_for(other, path),
    });
    let Msg::FileEvent { mtime_ms, .. } = msg else { unreachable!() };
    mtime_ms
}

// Park a doc on a freshly created board that is NOT the active one: create board-1
// (BoardCreate makes it active), switch back to board-0, then open onto board-1.
fn open_on_background_board(app: &mut Conn, path: &str) {
    app.send(&Msg::BoardCreate);
    app.recv_restore();
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_restore();
    app.send(&Msg::Open { path: path.into(), term_id: None, board_id: Some("board-1".into()) });
    app.recv_doc_opened_for(path);
}

fn wait_for_last_changed(daemon: &TestDaemon, what: &str, board: usize, path: &str, want: serde_json::Value) {
    daemon.wait_for_state(what, |v| doc_entry(v, board, path)["last_changed_ms"] == want);
}

// S3: a refresh after a real edit pushes the file's CURRENT mtime, and no
// doc_opened accompanies it. The watcher's own event for the edit is consumed
// first, so the event under assertion can only be the refresh's — without that,
// an empty handler would pass.
#[test]
fn doc_refresh_pushes_the_files_current_mtime() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    // Settle the open, then edit and consume the watcher's own event for that edit.
    settle_watcher(&mut app, &a);
    touch(&a);
    app.recv_file_event_for(&a);

    app.send(&Msg::DocRefresh { path: a.clone() });

    assert_eq!(
        recv_refresh_event(&mut app, &a),
        mtime_ms(&a),
        "doc_refresh must push the file's real current mtime"
    );
    // recv_refresh_event only catches a doc_opened that arrives BEFORE the
    // file_event; a handler pushing them the other way round would slip past it.
    assert!(
        none_within(&mut app, Duration::from_millis(500), |m| matches!(m, Msg::DocOpened(_))),
        "no doc_opened may trail the refresh's file_event either"
    );
}

// S4: the mtime is recorded, not just announced — it survives to state.json and
// back out through Restore after a daemon restart. The rest of the doc entry
// (read/via/last_opened_ms) and the dock are untouched: a refresh is not a re-open.
#[test]
fn doc_refresh_records_the_mtime_durably_and_changes_nothing_else() {
    let mut daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    // Two docs, so the dock-order assertion below can actually fail: `position()`
    // on a one-element dock is Some(0) no matter what, which pins nothing.
    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    let z = write_doc(&daemon.dir.join("docs/z.md"), "z\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened_for(&a);
    cli_open(&daemon.sock, &z);
    app.recv_doc_opened_for(&z);
    daemon.wait_for_state("both docs persisted", |v| has_doc(v, 0, &a) && has_doc(v, 0, &z));
    let before = doc_entry(&daemon.state_json(), 0, &a);

    settle_watcher(&mut app, &a);
    touch(&a);
    app.recv_file_event_for(&a);
    app.send(&Msg::DocRefresh { path: a.clone() });
    let pushed = recv_refresh_event(&mut app, &a);

    wait_for_last_changed(&daemon, "last_changed_ms recorded", 0, &a, json!(pushed));
    let after = doc_entry(&daemon.state_json(), 0, &a);
    // Fixed values, not `before`'s: the watcher can reach the doc before `before`
    // is read, and a refresh that sets one of these then leaves the two equal.
    assert_eq!(after["read"], json!(false), "doc_refresh must not mark the doc read");
    assert_eq!(after["via"], json!("cli"), "doc_refresh must not touch `via`");
    assert_eq!(after["last_opened_ms"], before["last_opened_ms"], "doc_refresh must not touch `last_opened_ms`");
    // persist.rs emits `docs` in dock order, so the index IS the dock position.
    // Refreshing `a` must not reorder it past `z`.
    let st = daemon.state_json();
    assert_eq!(
        (dock_index(&st, 0, &a), dock_index(&st, 0, &z)),
        (Some(0), Some(1)),
        "doc_refresh must not move the doc's dock slot"
    );
    // Tie the persisted value to the FILE, not merely to what was pushed: without
    // this the pair is self-consistent even if both are `now` rather than the mtime.
    assert_eq!(
        after["last_changed_ms"],
        json!(mtime_ms(&a)),
        "the persisted change time must be the file's mtime"
    );

    // Durable: the value comes back out of a cold restart.
    drop(app);
    daemon.restart();
    let mut app2 = daemon.connect_app();
    let docs = app2.recv_restore().docs;
    let entry = docs.iter().find(|d| d.path == a).expect("doc a survives restart");
    assert_eq!(
        entry.last_changed_ms,
        Some(pushed),
        "the refreshed mtime must survive a daemon restart"
    );
}

// S5: scoping. A doc parked on a background board is not refreshable; the same
// message after switching to that board is. The positive half is what makes the
// silence meaningful — it proves the first refresh was scoped out, not mis-set-up.
#[test]
fn doc_refresh_is_scoped_to_the_active_board() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    open_on_background_board(&mut app, &a);
    daemon.wait_for_state("doc a on board-1", |v| has_doc(v, 1, &a));

    // board-0 is active; board-1 owns the doc.
    app.send(&Msg::DocRefresh { path: a.clone() });
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| is_file_event_for(m, &a)),
        "a background-board doc must not be refreshable"
    );
    assert_eq!(
        doc_entry(&daemon.state_json(), 1, &a)["last_changed_ms"],
        json!(null),
        "the scoped-out refresh must not have recorded an mtime"
    );

    // Same message, now that its board is active.
    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    app.recv_restore();
    app.send(&Msg::DocRefresh { path: a.clone() });
    assert_eq!(
        recv_refresh_event(&mut app, &a),
        mtime_ms(&a),
        "the same refresh must work once the doc's board is active"
    );
}

// S6: the always-push contract. An unchanged file still gets a file_event, and it
// carries the mtime the earlier event reported — not `now`, and not nothing. This
// is the scenario that kills both a now_ms() handler and a "skip if unchanged" one.
#[test]
fn doc_refresh_pushes_even_when_the_mtime_is_unchanged() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    settle_watcher(&mut app, &a);
    touch(&a);
    let reported = app.recv_file_event_for(&a);
    assert_eq!(reported, mtime_ms(&a), "the watcher must have reported the edit, not an earlier event");

    // Nothing touches the file from here on; settle so the next event is the refresh's.
    settle_watcher(&mut app, &a);
    app.send(&Msg::DocRefresh { path: a.clone() });

    assert_eq!(
        recv_refresh_event(&mut app, &a),
        reported,
        "an unchanged file must still push, carrying the mtime already reported"
    );
}

// S7: a doc that nothing has written since it was opened still refreshes. The
// baseline is QUIESCENCE, not a null registry: opening a just-written doc makes
// FSEvents replay the file's own creation to the freshly-attached dir watch, so
// last_changed_ms is populated within milliseconds of the open (observed on this
// harness: a last_changed_ms 3ms BEFORE last_opened_ms). The drain below settles
// that event; nothing can touch the file afterwards, so the file_event that follows
// is attributable to the refresh alone. This is the unconditional kill for a
// do-nothing handler — with no edit to ride on, only the refresh can push.
#[test]
fn doc_refresh_works_on_a_doc_nothing_has_written_since_open() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    settle_watcher(&mut app, &a);

    app.send(&Msg::DocRefresh { path: a.clone() });
    let pushed = recv_refresh_event(&mut app, &a);
    assert_eq!(pushed, mtime_ms(&a), "the push must carry the file's real mtime");

    wait_for_last_changed(&daemon, "last_changed_ms recorded", 0, &a, json!(pushed));
}

// S8: repeat refreshes of an unchanged file are identical, not cumulative.
#[test]
fn doc_refresh_is_idempotent_on_repeat() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();
    settle_watcher(&mut app, &a);

    app.send(&Msg::DocRefresh { path: a.clone() });
    let first = recv_refresh_event(&mut app, &a);
    app.send(&Msg::DocRefresh { path: a.clone() });
    let second = recv_refresh_event(&mut app, &a);

    assert_eq!(first, second, "two refreshes of an unchanged file must agree");
    assert_eq!(first, mtime_ms(&a), "and both must be the file's real mtime");
}

// S9: an unknown path is a silent no-op — no push, no err — and an unrelated open
// doc is untouched (proved by refreshing it successfully afterwards).
#[test]
fn doc_refresh_unknown_path_is_a_silent_noop() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();

    // A real file, canonicalized, that was never opened: the stat SUCCEEDS, so this
    // exercises the registry-miss branch rather than the deleted-file branch S10
    // already covers.
    let unopened = write_doc(&daemon.dir.join("docs/unopened.md"), "u\n");
    app.send(&Msg::DocRefresh { path: unopened.clone() });
    // Scoped to that path: the watcher may still be reporting either file's own
    // creation, and that noise is not what this scenario is about.
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| {
            is_file_event_for(m, &unopened) || matches!(m, Msg::Err { .. })
        }),
        "a path absent from the registry must produce neither a file_event nor an err"
    );

    app.send(&Msg::DocRefresh { path: a.clone() });
    assert_eq!(
        recv_refresh_event(&mut app, &a),
        mtime_ms(&a),
        "the unrelated open doc must still refresh normally"
    );
}

// S10: an open doc whose file has been deleted emits nothing (watch_loop's
// deleted-file rule), sends no err, and does not wedge the handler for other docs.
#[test]
fn doc_refresh_on_a_deleted_file_emits_nothing() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    let b = write_doc(&daemon.dir.join("docs/b.md"), "b\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened_for(&a);
    cli_open(&daemon.sock, &b);
    app.recv_doc_opened_for(&b);

    std::fs::remove_file(&a).unwrap();
    // The deletion itself is a watch event; the watcher is silent for it too.
    app.send(&Msg::DocRefresh { path: a.clone() });
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| {
            is_file_event_for(m, &a) || matches!(m, Msg::Err { .. })
        }),
        "a deleted file must produce neither a file_event nor an err"
    );

    app.send(&Msg::DocRefresh { path: b.clone() });
    assert_eq!(
        recv_refresh_event(&mut app, &b),
        mtime_ms(&b),
        "a surviving doc must still refresh after a deleted-file no-op"
    );
}

// S21: the watcher-missed-it case — #89's reason to exist. An edit made while the
// doc's board is in the background is dropped by watch_loop (it matches events
// against the ACTIVE board's registry when the debounced batch is processed), so
// only a refresh can deliver it. The sequence below is load-bearing: the
// none_within both proves the silence and lets the 100ms debounce window expire
// BEFORE the board switch, otherwise the watcher would deliver the edit itself
// against the newly-active board and an empty handler would pass.
#[test]
fn doc_refresh_delivers_an_edit_the_watcher_never_announced() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    open_on_background_board(&mut app, &a);
    daemon.wait_for_state("doc a on board-1", |v| has_doc(v, 1, &a));
    let before_edit = mtime_ms(&a);

    // Edit while board-0 is active. Sleep first so the new mtime is distinguishable
    // at ms resolution — without that, a handler replaying an open-time snapshot
    // would survive this test.
    std::thread::sleep(Duration::from_millis(300));
    touch(&a);
    assert!(
        none_within(&mut app, Duration::from_millis(500), |m| is_file_event_for(m, &a)),
        "an edit to a background-board doc must not be announced"
    );
    let after_edit = mtime_ms(&a);
    assert_ne!(after_edit, before_edit, "the edit must move the mtime for this test to mean anything");

    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    app.recv_restore();
    // The switch heals nothing: the registry still has no record of the edit.
    wait_for_last_changed(&daemon, "board-1 doc still unchanged", 1, &a, json!(null));

    app.send(&Msg::DocRefresh { path: a.clone() });
    let pushed = recv_refresh_event(&mut app, &a);
    assert_eq!(pushed, after_edit, "the refresh must deliver the post-edit mtime");
    assert_ne!(pushed, before_edit, "and it must not be the pre-edit mtime");

    wait_for_last_changed(&daemon, "board-1 doc now carries the edit", 1, &a, json!(pushed));
}

// S22: the refresh RE-STATS; it never re-announces what the registry already
// believes. This is S21's shape with a POPULATED baseline instead of a null one,
// and it is the only test that distinguishes the two. A handler that answers from
// `last_changed_ms` and stats only when that is `None`
//
//     let v = info.last_changed_ms.unwrap_or(stat_derived_mtime);
//
// passes every other test in this file — S3/S6 drain the watcher so registry and
// file already agree, S7/S8 never write the file, and S5/S21 have a null registry
// so the fallback fires. Only here is the registry populated AND stale, which is
// exactly the state #89 exists to repair (the spec's "Asymmetric across boards"
// limitation, and every watcher-miss cause in its Context).
#[test]
fn doc_refresh_restats_rather_than_replaying_a_populated_registry() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    let a = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    cli_open(&daemon.sock, &a);
    app.recv_doc_opened();
    settle_watcher(&mut app, &a);

    // First edit, seen by the watcher: board-0's registry is now POPULATED.
    touch(&a);
    app.recv_file_event_for(&a);
    let first_edit = mtime_ms(&a);
    wait_for_last_changed(&daemon, "board-0 registry populated", 0, &a, json!(first_edit));

    // Background board-0 (BoardCreate makes the new board active), then edit again.
    // watch_loop matches against the ACTIVE board's registry, so this edit is
    // dropped and the registry's populated value goes stale.
    app.send(&Msg::BoardCreate);
    app.recv_restore();
    std::thread::sleep(Duration::from_millis(300));
    touch(&a);
    assert!(
        none_within(&mut app, Duration::from_millis(500), |m| is_file_event_for(m, &a)),
        "an edit made while the doc's board is backgrounded must not be announced"
    );
    let second_edit = mtime_ms(&a);
    assert_ne!(second_edit, first_edit, "the second edit must move the mtime");

    // Back to board-0, where the registry still carries the FIRST edit's mtime.
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_restore();
    // Settle before attributing anything to the refresh, as every other test here
    // does: board-0 is active again, so a late watcher event could otherwise arrive
    // carrying the second edit and be mistaken for the refresh's push.
    settle_watcher(&mut app, &a);
    wait_for_last_changed(&daemon, "board-0 registry still stale", 0, &a, json!(first_edit));

    app.send(&Msg::DocRefresh { path: a.clone() });
    let pushed = recv_refresh_event(&mut app, &a);
    assert_eq!(pushed, second_edit, "the refresh must report what the file says now");
    assert_ne!(
        pushed, first_edit,
        "replaying the registry's stored last_changed_ms is the bug this pins"
    );
    // Recorded, not merely announced. S4 cannot pin this: there the watcher wrote
    // the same value moments earlier, so an arm that skips its registry write is
    // invisible. Here the stored value is stale, so only the refresh's own write
    // can move it.
    wait_for_last_changed(&daemon, "board-0 registry caught up", 0, &a, json!(second_edit));
}
