// #256: the daemon finds a doc's change by comparing the file with what it
// last saw for that board. A change made while the doc's board was in the
// background is reported when the board is shown: its `restore` carries the
// new `last_changed_ms`, and a `file_event` follows it.

mod common;

use std::time::{Duration, SystemTime};

use common::{
    Conn, Restore, TestDaemon, doc_entry, has_doc, is_file_event_for, mtime_ms, none_within, touch, write_doc,
};
use serde_json::json;
use tarmac_protocol::Msg;

fn quiet(app: &mut Conn, path: &str) -> bool {
    none_within(app, Duration::from_millis(800), |m| is_file_event_for(m, path))
}

fn open_on(app: &mut Conn, board: &str, path: &str) {
    app.send(&Msg::Open { path: path.into(), term_id: None, board_id: Some(board.into()) });
    app.recv_doc_opened_for(path);
}

fn switch_to(app: &mut Conn, board: &str) -> Restore {
    app.send(&Msg::BoardSwitch { board_id: board.into() });
    app.recv_restore_for(board)
}

fn last_changed(restore: &Restore, path: &str) -> Option<u64> {
    restore.docs.iter().find(|d| d.path == path).expect("the doc is on the board").last_changed_ms
}

// board-1 is made and left active.
fn two_boards(app: &mut Conn) {
    app.send(&Msg::BoardCreate);
    app.recv_restore_for("board-1");
}

#[test]
fn a_change_in_the_background_is_reported_when_its_board_is_shown() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let y = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    two_boards(&mut app);
    open_on(&mut app, "board-1", &y);
    // FSEvents replays the file's creation to a watch that was just attached.
    quiet(&mut app, &y);

    switch_to(&mut app, "board-0");
    touch(&y);
    let edited = mtime_ms(&y);
    assert!(quiet(&mut app, &y), "board-0 is active and does not have the doc");

    let restore = switch_to(&mut app, "board-1");
    assert_eq!(last_changed(&restore, &y), Some(edited), "the restore carries the change");
    assert_eq!(app.recv_file_event_for(&y), edited, "and a file_event follows it");
    // Another file of the directory wakes the daemon for one more look.
    write_doc(&daemon.dir.join("docs/other.txt"), "other\n");
    assert!(quiet(&mut app, &y), "the change is reported one time");
}

// The board that a delete leaves active is sent like any other.
#[test]
fn deleting_the_active_board_reports_the_changes_of_the_board_that_is_shown() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let y = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    open_on(&mut app, "board-0", &y);
    quiet(&mut app, &y);
    two_boards(&mut app);

    touch(&y);
    let edited = mtime_ms(&y);
    assert!(quiet(&mut app, &y), "board-1 is active and does not have the doc");

    app.send(&Msg::BoardDelete { board_id: "board-1".into() });
    let restore = app.recv_restore_for("board-0");
    assert_eq!(last_changed(&restore, &y), Some(edited));
    assert_eq!(app.recv_file_event_for(&y), edited);
}

// What the daemon saw is what an app was told. A change made with no app is
// told to the app that connects: the app of a reconnect keeps its cards, and
// reads a doc again on a file_event only.
#[test]
fn a_change_made_with_no_app_connected_is_reported_at_the_connect() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let y = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    open_on(&mut app, "board-0", &y);
    quiet(&mut app, &y);
    drop(app);
    // The daemon sees the disconnect, then the watcher's wake for the edit passes.
    std::thread::sleep(Duration::from_millis(300));
    touch(&y);
    let edited = mtime_ms(&y);
    // Saved with no app, so a daemon that stops here keeps the time of the change.
    daemon.wait_for_state("the change in the state file", |v| doc_entry(v, 0, &y)["last_changed_ms"] == json!(edited));
    std::thread::sleep(Duration::from_millis(300));

    let mut app = daemon.connect_app();
    let restore = app.recv_restore_for("board-0");
    assert_eq!(last_changed(&restore, &y), Some(edited));
    assert_eq!(app.recv_file_event_for(&y), edited);
}

// A writer that puts the mtime back. The length tells.
#[test]
fn a_change_that_keeps_the_mtime_is_reported() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let y = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    open_on(&mut app, "board-0", &y);
    quiet(&mut app, &y);

    let kept = std::fs::metadata(&y).unwrap().modified().unwrap();
    let kept_ms = mtime_ms(&y);
    let file = std::fs::File::options().append(true).open(&y).unwrap();
    std::io::Write::write_all(&mut &file, b"more\n").unwrap();
    file.set_modified(kept).unwrap();
    drop(file);

    app.recv_until("a file_event with the mtime that was kept", |m| {
        matches!(m, Msg::FileEvent { path, mtime_ms } if *path == y && *mtime_ms == kept_ms)
    });
}

#[test]
fn a_doc_on_two_boards_is_reported_to_each_board() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let y = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    open_on(&mut app, "board-0", &y);
    two_boards(&mut app);
    open_on(&mut app, "board-1", &y);
    switch_to(&mut app, "board-0");
    quiet(&mut app, &y);

    touch(&y);
    let edited = mtime_ms(&y);
    assert_eq!(app.recv_file_event_since(&y, edited), edited, "board-0 is active and has the doc");

    let restore = switch_to(&mut app, "board-1");
    assert_eq!(last_changed(&restore, &y), Some(edited), "board-1 has its own record of the change");
    assert_eq!(app.recv_file_event_for(&y), edited);

    let restore = switch_to(&mut app, "board-0");
    assert_eq!(last_changed(&restore, &y), Some(edited));
    assert!(quiet(&mut app, &y), "board-0 was told when the file changed");
}

// What is held for an app is in memory only. After a restart the restore has
// the time of the change, and the first look takes the file as it is.
#[test]
fn a_restart_keeps_the_time_of_a_change_and_reports_nothing() {
    let mut daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    open_on(&mut app, "board-0", &doc);
    quiet(&mut app, &doc);
    touch(&doc);
    let edited = mtime_ms(&doc);
    assert_eq!(app.recv_file_event_since(&doc, edited), edited);
    daemon.wait_for_state("the change in the state file", |v| doc_entry(v, 0, &doc)["last_changed_ms"] == json!(edited));
    drop(app);

    daemon.restart();
    let mut app = daemon.connect_app();
    let restore = app.recv_restore_for("board-0");
    assert_eq!(last_changed(&restore, &doc), Some(edited));
    assert!(quiet(&mut app, &doc), "the app that built its cards from this restore needs no file_event");
}

// The comparison is "different", not "newer than the open": a file whose mtime
// is in the future has not changed.
#[test]
fn a_switch_reports_nothing_for_a_doc_that_did_not_change() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let same = write_doc(&daemon.dir.join("docs/same.md"), "same\n");
    let future = write_doc(&daemon.dir.join("docs/future.md"), "future\n");
    std::fs::File::options()
        .write(true)
        .open(&future)
        .unwrap()
        .set_modified(SystemTime::now() + Duration::from_secs(3600))
        .unwrap();
    two_boards(&mut app);
    open_on(&mut app, "board-1", &same);
    open_on(&mut app, "board-1", &future);
    none_within(&mut app, Duration::from_millis(800), |m| matches!(m, Msg::FileEvent { .. }));

    switch_to(&mut app, "board-0");
    let restore = switch_to(&mut app, "board-1");
    assert_eq!(last_changed(&restore, &same), None);
    assert_eq!(last_changed(&restore, &future), None);
    assert!(
        none_within(&mut app, Duration::from_millis(800), |m| matches!(m, Msg::FileEvent { .. })),
        "no doc changed"
    );
}

// The first look after a start takes each file as it is: a doc that came from
// the state file has not changed.
#[test]
fn a_restart_reports_nothing_for_a_doc_that_did_not_change() {
    let mut daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&daemon.dir.join("docs/a.md"), "a\n");
    open_on(&mut app, "board-0", &doc);
    daemon.wait_for_state("the doc in the state file", |v| has_doc(v, 0, &doc));
    quiet(&mut app, &doc);
    drop(app);

    daemon.restart();
    let mut app = daemon.connect_app();
    let restore = app.recv_restore_for("board-0");
    assert_eq!(last_changed(&restore, &doc), None);
    assert!(quiet(&mut app, &doc), "the file is as it was");

    touch(&doc);
    let edited = mtime_ms(&doc);
    assert_eq!(app.recv_file_event_since(&doc, edited), edited, "and a change after the start is reported");
}
