// #311 / spec 2611.0002: `doc_data` names the data file that an HTML doc
// reads. The daemon answers it with a `file_event` for that file, and reports
// each later change of it as it reports a doc's: in a look of the active
// board, and at the switch to the doc's board.
//
// A check that no `file_event` comes passes for the wrong reason when no look
// runs. So each one forces a look first (`look_with_none_for`): it changes a
// doc that is open beside the data file and waits for that doc's event.

mod common;

use std::path::Path;
use std::time::Duration;

use common::{Conn, TestDaemon, edit, is_file_event_for, mtime_ms, none_within, quiet, temp_dir, write_doc};
use serde_json::json;
use tarmac_protocol::{BoardViewport, Msg};

fn doc_data(app: &mut Conn, board: &str, doc: &str, data: Option<&str>) {
    app.send(&Msg::DocData { board_id: board.into(), path: doc.into(), data: data.map(str::to_string) });
}

fn is_event_for_any(msg: &Msg, paths: &[&str]) -> bool {
    paths.iter().any(|path| is_file_event_for(msg, path))
}

/// Waits for `msg_is`, and fails on a `file_event` for any of `paths` before
/// it: `recv_until` would drop that event.
fn recv_with_none_for(app: &mut Conn, what: &str, paths: &[&str], mut msg_is: impl FnMut(&Msg) -> bool) {
    app.recv_until(what, |m| {
        assert!(!is_event_for_any(m, paths), "a file_event before {what}: {m:?}");
        msg_is(m)
    });
}

/// Makes the daemon look at the active board, then fails on a `file_event`
/// for any of `paths` before that look's event for `other`, or within the
/// window after it: the events of one look come in no set order.
fn look_with_none_for(app: &mut Conn, other: &str, paths: &[&str]) {
    let edited = edit(other);
    recv_with_none_for(app, &format!("the look's file_event for {other}"), paths, |m| {
        matches!(m, Msg::FileEvent { path, mtime_ms } if path == other && *mtime_ms >= edited)
    });
    assert!(
        none_within(app, Duration::from_millis(800), |m| is_event_for_any(m, paths)),
        "a file_event for one of {paths:?} after the look"
    );
}

/// Fails on a `file_event` for any of `paths` that answers what the test sent
/// before: the daemon handles the frames of one connection in order, so the
/// answer to a `doc_refresh` sent now comes after it.
fn none_at_once_for(app: &mut Conn, other: &str, paths: &[&str]) {
    app.send(&Msg::DocRefresh { path: other.into() });
    recv_with_none_for(app, &format!("the refresh's file_event for {other}"), paths, |m| {
        matches!(m, Msg::FileEvent { path, .. } if path == other)
    });
}

/// `board_switch`, failing on a `file_event` for `data` before the restore.
fn switch_with_restore_first(app: &mut Conn, board: &str, data: &str) {
    app.send(&Msg::BoardSwitch { board_id: board.into() });
    recv_with_none_for(app, &format!("restore for {board}"), &[data], |m| {
        matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some(board))
    });
}

/// An HTML doc and a doc beside it, both open on board-0, and the data file
/// `stats.json` beside them. `other` is the doc a test changes to force a
/// look.
struct Card {
    dash: String,
    other: String,
    stats: String,
}

impl Card {
    /// The three files, with no doc open.
    fn write(daemon: &TestDaemon) -> Self {
        Card {
            dash: write_doc(&daemon.dir.join("docs/dash.html"), "<p>dash</p>\n"),
            other: write_doc(&daemon.dir.join("docs/other.md"), "other\n"),
            stats: write_doc(&daemon.dir.join("docs/stats.json"), "{}\n"),
        }
    }

    fn open(daemon: &TestDaemon, app: &mut Conn) -> Self {
        let card = Card::write(daemon);
        app.open_on("board-0", &card.dash);
        app.open_on("board-0", &card.other);
        card
    }

    /// A path beside the card's doc, made as text, with no file made.
    fn beside(&self, name: &str) -> String {
        format!("{}/{name}", Path::new(&self.dash).parent().unwrap().display())
    }

    /// `doc_data` for `dash` on board-0, and its answer.
    fn register(&self, app: &mut Conn) {
        self.register_file(app, &self.stats);
    }
}

// S36
#[test]
fn a_doc_data_is_answered_with_a_file_event_for_the_data_file() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);

    doc_data(&mut app, "board-0", &card.dash, Some(&card.stats));
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats), "the data file's mtime");
}

// S36a
#[test]
fn the_answer_takes_the_data_file_as_seen() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);

    look_with_none_for(&mut app, &card.other, &[&card.stats]);
}

// S37
#[test]
fn one_write_of_the_data_file_is_one_file_event() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);

    let edited = edit(&card.stats);
    assert_eq!(app.recv_file_event_since(&card.stats, edited), edited);
    assert!(quiet(&mut app, &card.stats), "one file_event for one write");
}

// S38
#[test]
fn the_same_doc_data_again_is_answered_again() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);
    assert!(quiet(&mut app, &card.stats), "the file did not change");

    doc_data(&mut app, "board-0", &card.dash, Some(&card.stats));
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats));
}

// S39
#[test]
fn a_data_file_that_is_not_there_is_reported_when_it_is_made() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let later = card.beside("later.json");

    doc_data(&mut app, "board-0", &card.dash, Some(&later));
    look_with_none_for(&mut app, &card.other, &[&later]);

    write_doc(Path::new(&later), "[1]\n");
    assert_eq!(app.recv_file_event_for(&later), mtime_ms(&later));
    assert!(quiet(&mut app, &later), "one file_event for one file made");
}

// S40
#[test]
fn a_doc_data_with_no_data_clears_the_data_file() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);

    doc_data(&mut app, "board-0", &card.dash, None);
    edit(&card.stats);
    look_with_none_for(&mut app, &card.other, &[&card.stats]);
}

// S40a
#[test]
fn a_doc_data_with_another_file_replaces_the_data_file() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);
    let next = write_doc(&daemon.dir.join("docs/next.json"), "{}\n");

    doc_data(&mut app, "board-0", &card.dash, Some(&next));
    assert_eq!(app.recv_file_event_for(&next), mtime_ms(&next), "the new file is answered");

    edit(&card.stats);
    look_with_none_for(&mut app, &card.other, &[&card.stats]);
}

// S41. Each file that is refused is there, beside the doc when the daemon
// resolves it: a daemon that took it would report it. The daemon's cwd is the
// parent of the docs' directory, so that the relative name names a file too.
// A file in a subdirectory is taken since 2611.0005 (S9).
#[test]
fn a_doc_data_that_is_refused_records_nothing() {
    let cwd = temp_dir();
    let away = temp_dir();
    let daemon = TestDaemon::start_with(|cmd| {
        cmd.current_dir(&cwd);
    });
    let mut app = daemon.connect_app_drained();
    let dash = write_doc(&cwd.join("docs/dash.html"), "<p>dash</p>\n");
    let other = write_doc(&cwd.join("docs/other.md"), "other\n");
    app.open_on("board-0", &dash);
    app.open_on("board-0", &other);
    let docs = Path::new(&dash).parent().unwrap().display().to_string();

    let above = write_doc(&cwd.join("above.json"), "{}\n");
    let elsewhere = write_doc(&away.join("away.json"), "{}\n");
    let relative_file = write_doc(&cwd.join("docs/relative.json"), "{}\n");
    let relative = "docs/relative.json".to_string();
    let through_sub_file = write_doc(&cwd.join("docs/through.json"), "{}\n");
    let through_sub = format!("{docs}/sub/../through.json");
    let the_dir_above = format!("{docs}/..");
    let no_doc = format!("{docs}/nope.html");
    let of_no_doc = write_doc(&cwd.join("docs/of-no-doc.json"), "{}\n");
    let of_no_board = write_doc(&cwd.join("docs/of-no-board.json"), "{}\n");

    for data in [&above, &elsewhere, &relative, &through_sub, &the_dir_above] {
        doc_data(&mut app, "board-0", &dash, Some(data));
    }
    doc_data(&mut app, "board-0", &no_doc, Some(&of_no_doc));
    doc_data(&mut app, "board-9", &dash, Some(&of_no_board));

    let refused = [&above, &elsewhere, &relative, &through_sub, &the_dir_above, &of_no_doc, &of_no_board];
    let refused: Vec<&str> = refused.iter().map(|p| p.as_str()).collect();
    none_at_once_for(&mut app, &other, &refused);
    for file in [&above, &elsewhere, &relative_file, &through_sub_file, &of_no_doc, &of_no_board] {
        edit(file);
    }
    look_with_none_for(&mut app, &other, &refused);

    let taken = write_doc(&cwd.join("docs/taken.json"), "{}\n");
    doc_data(&mut app, "board-0", &dash, Some(&taken));
    assert_eq!(app.recv_file_event_for(&taken), mtime_ms(&taken), "the same doc takes a file beside it");

    let _ = std::fs::remove_dir_all(&cwd);
    let _ = std::fs::remove_dir_all(&away);
}

// S42. `other` keeps the directory watched.
#[test]
fn a_closed_doc_reads_its_data_file_no_more() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);

    app.send(&Msg::DocClose { path: card.dash.clone() });
    edit(&card.stats);
    look_with_none_for(&mut app, &card.other, &[&card.stats]);
}

// S43
#[test]
fn a_data_file_that_two_docs_read_is_one_file_event_for_a_change() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let dash2 = write_doc(&daemon.dir.join("docs/dash2.html"), "<p>dash2</p>\n");
    app.open_on("board-0", &dash2);
    card.register(&mut app);
    doc_data(&mut app, "board-0", &dash2, Some(&card.stats));
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats));
    assert!(quiet(&mut app, &card.stats));

    let edited = edit(&card.stats);
    assert_eq!(app.recv_file_event_since(&card.stats, edited), edited);
    assert!(quiet(&mut app, &card.stats), "one file_event for one write");
}

// S43, a data file that is also a doc of the board.
#[test]
fn a_data_file_that_is_also_a_doc_is_one_file_event_for_a_change() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    app.open_on("board-0", &card.stats);
    card.register(&mut app);
    assert!(quiet(&mut app, &card.stats));

    let edited = edit(&card.stats);
    assert_eq!(app.recv_file_event_since(&card.stats, edited), edited);
    assert!(quiet(&mut app, &card.stats), "one file_event for one write");
}

/// A card whose doc is on board-1, in the background, and whose `other` is
/// on board-0, the active board. A test forces a look of board-0 before its
/// switch to board-1: the wake of an open would look at board-1 after it, and
/// report the data file without the look of the switch.
fn card_in_the_background(daemon: &TestDaemon, app: &mut Conn) -> Card {
    let card = Card::write(daemon);
    app.open_on("board-0", &card.other);
    app.create_board("board-1");
    app.open_on("board-1", &card.dash);
    app.switch_to("board-0");
    card
}

// S44
#[test]
fn a_doc_data_for_a_board_in_the_background_is_answered_at_its_switch() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = card_in_the_background(&daemon, &mut app);

    doc_data(&mut app, "board-1", &card.dash, Some(&card.stats));
    none_at_once_for(&mut app, &card.other, &[&card.stats]);
    look_with_none_for(&mut app, &card.other, &[&card.stats]);

    switch_with_restore_first(&mut app, "board-1", &card.stats);
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats));
}

// The spec's choices 6 and 9: a `doc_data` sent again for a board in the
// background (an app that connected again) is answered at the switch as the
// first was, with the file not changed.
#[test]
fn the_same_doc_data_again_for_a_board_in_the_background_is_answered_at_its_switch() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = card_in_the_background(&daemon, &mut app);
    doc_data(&mut app, "board-1", &card.dash, Some(&card.stats));
    look_with_none_for(&mut app, &card.other, &[&card.stats]);
    app.switch_to("board-1");
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats));
    switch_with_restore_first(&mut app, "board-0", &card.stats);

    doc_data(&mut app, "board-1", &card.dash, Some(&card.stats));
    none_at_once_for(&mut app, &card.other, &[&card.stats]);
    look_with_none_for(&mut app, &card.other, &[&card.stats]);
    switch_with_restore_first(&mut app, "board-1", &card.stats);
    assert_eq!(app.recv_file_event_for(&card.stats), mtime_ms(&card.stats));
}

// S45. A doc of board-1 beside the data file is changed after it, and its
// event awaited, so that the wake of the data file's write is spent before
// the switch back: only the look of the switch can then report the change.
#[test]
fn a_change_of_a_data_file_in_the_background_is_reported_at_the_switch() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);
    let b1 = write_doc(&daemon.dir.join("docs/b1.md"), "b1\n");
    app.create_board("board-1");
    app.open_on("board-1", &b1);

    let edited = edit(&card.stats);
    let b1_edited = edit(&b1);
    recv_with_none_for(&mut app, "file_event for b1", &[&card.stats], |m| {
        matches!(m, Msg::FileEvent { path, mtime_ms } if *path == b1 && *mtime_ms >= b1_edited)
    });
    assert!(quiet(&mut app, &card.stats), "board-1 does not read the data file");

    switch_with_restore_first(&mut app, "board-0", &card.stats);
    assert_eq!(app.recv_file_event_for(&card.stats), edited);
}

// S46. `doc_data` saves nothing itself, so a layout makes the save.
#[test]
fn the_data_file_is_not_in_the_state_file() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    card.register(&mut app);

    let viewport = BoardViewport { zoom: 1.25, cx: 10.0, cy: 20.0 };
    app.send(&Msg::Layout { dock: vec![], tiles: vec![], board: Some(viewport), board_id: None });
    daemon.wait_for_state("the layout's viewport", |v| v["boards"][0]["board"]["zoom"] == json!(1.25));
    let state = daemon.state_json().to_string();
    assert!(state.contains("dash.html"), "the doc is in the state file");
    assert!(!state.contains("stats.json"), "the data file is not: {state}");
}

// Spec 2611.0005: a data file in a directory under the doc's own.

impl Card {
    /// The card's directory, as the registry writes it.
    /// `doc_data` for `dash` naming `data`, and its answer.
    fn register_file(&self, app: &mut Conn, data: &str) {
        doc_data(app, "board-0", &self.dash, Some(data));
        assert_eq!(app.recv_file_event_for(data), mtime_ms(data));
    }
}

/// The card with `sub/stats.json` written and registered, and the looks that
/// the opens and the registration woke waited out.
fn card_reading_sub(daemon: &TestDaemon, app: &mut Conn) -> (Card, String) {
    let card = Card::open(daemon, app);
    let stats = write_doc(&daemon.dir.join("docs/sub/stats.json"), "{}\n");
    card.register_file(app, &stats);
    assert!(quiet(app, &stats), "the file did not change");
    (card, stats)
}

// S8. Each `data` is refused whole. The files they lead to are there, and a
// file_event would carry the text as sent or the file it leads to. The
// daemon's cwd is the card's directory, so that the relative name names a
// file too.
// A doc named with `//` is judged from its registry key: the same `//` in its
// `data` is refused.
#[test]
fn a_doc_data_that_is_not_a_clean_path_under_the_directory_is_refused() {
    let root = temp_dir();
    let dir = std::fs::canonicalize(&root).unwrap().join("docs");
    std::fs::create_dir_all(&dir).unwrap();
    let daemon = TestDaemon::start_with(|cmd| {
        cmd.current_dir(&dir);
    });
    let mut app = daemon.connect_app_drained();
    let dash = write_doc(&dir.join("dash.html"), "<p>dash</p>\n");
    let other = write_doc(&dir.join("other.md"), "other\n");
    app.open_on("board-0", &dash);
    app.open_on("board-0", &other);
    let d = dir.display().to_string();
    let parent = dir.parent().unwrap().display().to_string();

    let beside = write_doc(&dir.join("x.json"), "{}\n");
    let in_sub = write_doc(&dir.join("sub/x.json"), "{}\n");
    let above = write_doc(&dir.parent().unwrap().join("x.json"), "{}\n");
    let elsewhere = write_doc(&dir.parent().unwrap().join("away/x.json"), "{}\n");
    let sibling = write_doc(&dir.parent().unwrap().join("docsx/x.json"), "{}\n");
    let sent = [
        format!("{d}/sub/../x.json"),
        format!("{d}/../x.json"),
        format!("{d}/sub/../../away/x.json"),
        format!("{d}/./x.json"),
        format!("{d}/sub/./x.json"),
        format!("{d}//sub/x.json"),
        format!("{d}/sub/x.json/"),
        format!("{d}x/x.json"),
        d.clone(),
        format!("{parent}/x.json"),
        "sub/x.json".to_string(),
    ];
    for data in &sent {
        doc_data(&mut app, "board-0", &dash, Some(data));
    }
    let under_doubled = format!("{parent}//docs/sub/x.json");
    doc_data(&mut app, "board-0", &format!("{parent}//docs/dash.html"), Some(&under_doubled));

    let led_to = [&beside, &in_sub, &above, &elsewhere, &sibling, &d, &under_doubled];
    let refused: Vec<&str> = sent.iter().map(String::as_str).chain(led_to.iter().map(|p| p.as_str())).collect();
    none_at_once_for(&mut app, &other, &refused);
    for file in [&beside, &in_sub, &above, &elsewhere, &sibling] {
        edit(file);
    }
    write_doc(&dir.join("made.txt"), "a change of the directory itself\n");
    look_with_none_for(&mut app, &other, &refused);

    doc_data(&mut app, "board-0", &dash, Some(&in_sub));
    assert_eq!(app.recv_file_event_for(&in_sub), mtime_ms(&in_sub), "the same doc takes a file under it");

    let _ = std::fs::remove_dir_all(&root);
}

// S34
#[test]
fn a_doc_data_with_a_hidden_name_below_the_directory_is_refused() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let hidden = [
        write_doc(&daemon.dir.join("docs/.x.json"), "{}\n"),
        write_doc(&daemon.dir.join("docs/.cfg/x.json"), "{}\n"),
        write_doc(&daemon.dir.join("docs/sub/.x.json"), "{}\n"),
    ];
    let refused: Vec<&str> = hidden.iter().map(String::as_str).collect();
    for data in &refused {
        doc_data(&mut app, "board-0", &card.dash, Some(data));
    }
    none_at_once_for(&mut app, &card.other, &refused);
    for file in &refused {
        edit(file);
    }
    look_with_none_for(&mut app, &card.other, &refused);

    let dash = write_doc(&daemon.dir.join(".hid/dash.html"), "<p>dash</p>\n");
    let data = write_doc(&daemon.dir.join(".hid/sub/x.json"), "{}\n");
    app.open_on("board-0", &dash);
    doc_data(&mut app, "board-0", &dash, Some(&data));
    assert_eq!(app.recv_file_event_for(&data), mtime_ms(&data), "a doc's own directory may be hidden");
}

// S9
#[test]
fn a_doc_data_for_a_file_in_a_subdirectory_is_answered_with_a_file_event() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let stats = write_doc(&daemon.dir.join("docs/sub/stats.json"), "{}\n");

    doc_data(&mut app, "board-0", &card.dash, Some(&stats));
    assert_eq!(app.recv_file_event_for(&stats), mtime_ms(&stats));
}

// S10. No look is forced: only a watch of `sub` can report the write.
#[test]
fn one_write_of_a_data_file_in_a_subdirectory_is_one_file_event() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (_card, stats) = card_reading_sub(&daemon, &mut app);

    let edited = edit(&stats);
    assert_eq!(app.recv_file_event_since(&stats, edited), edited);
    assert!(quiet(&mut app, &stats), "one file_event for one write");
}

/// Each `file_event` for `path` until none comes for the `quiet` window, the
/// first waited for as long as `recv_file_event_for` waits.
fn file_events_until_quiet(app: &mut Conn, path: &str) -> Vec<u64> {
    let mut seen = vec![app.recv_file_event_for(path)];
    let mut take = |m: &Msg| match m {
        Msg::FileEvent { path: p, mtime_ms } if p == path => {
            seen.push(*mtime_ms);
            true
        }
        _ => false,
    };
    while !none_within(app, Duration::from_millis(800), &mut take) {}
    seen
}

// S11
#[test]
fn a_data_file_in_a_subdirectory_replaced_by_a_rename_is_reported() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (_card, stats) = card_reading_sub(&daemon, &mut app);

    let written = daemon.dir.join("docs/sub/stats.json.new");
    std::fs::write(&written, "{\"n\":2}\n").unwrap();
    std::fs::rename(&written, &stats).unwrap();
    let events = file_events_until_quiet(&mut app, &stats);
    assert_eq!(events.last(), Some(&mtime_ms(&stats)), "{events:?}");
}

// S12
#[test]
fn a_data_file_that_is_not_there_in_a_subdirectory_is_reported_when_it_is_made() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    std::fs::create_dir_all(daemon.dir.join("docs/sub")).unwrap();
    let new = card.beside("sub/new.json");

    doc_data(&mut app, "board-0", &card.dash, Some(&new));
    look_with_none_for(&mut app, &card.other, &[&new]);

    write_doc(Path::new(&new), "[1]\n");
    assert_eq!(app.recv_file_event_for(&new), mtime_ms(&new));
    assert!(quiet(&mut app, &new), "one file_event for one file made");
}

// S13. The write comes after the look that the `mkdir` wakes: a write in
// that look's window would be reported with no watch of `sub`.
#[test]
fn a_data_file_in_a_subdirectory_that_is_made_later_is_reported() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let stats = card.beside("sub/stats.json");
    doc_data(&mut app, "board-0", &card.dash, Some(&stats));
    look_with_none_for(&mut app, &card.other, &[&stats]);

    std::fs::create_dir(daemon.dir.join("docs/sub")).unwrap();
    assert!(quiet(&mut app, &stats));
    write_doc(Path::new(&stats), "{}\n");
    assert_eq!(app.recv_file_event_for(&stats), mtime_ms(&stats));
}

// S15
#[test]
fn one_write_of_a_data_file_two_levels_down_is_one_file_event() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let stats = write_doc(&daemon.dir.join("docs/a/b/stats.json"), "{}\n");
    card.register_file(&mut app, &stats);
    assert!(quiet(&mut app, &stats));

    let edited = edit(&stats);
    assert_eq!(app.recv_file_event_since(&stats, edited), edited);
    assert!(quiet(&mut app, &stats), "one file_event for one write");
}

// S16
#[test]
fn a_subdirectory_removed_and_made_again_is_still_watched() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (_card, stats) = card_reading_sub(&daemon, &mut app);

    let sub = daemon.dir.join("docs/sub");
    std::fs::remove_dir_all(&sub).unwrap();
    std::fs::create_dir(&sub).unwrap();
    assert!(quiet(&mut app, &stats));
    write_doc(Path::new(&stats), "[2]\n");
    assert_eq!(app.recv_file_event_for(&stats), mtime_ms(&stats));
}

// S20a
#[test]
fn a_subdirectory_that_another_doc_still_reads_in_stays_watched() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let dash2 = write_doc(&daemon.dir.join("docs/dash2.html"), "<p>dash2</p>\n");
    app.open_on("board-0", &dash2);
    let a = write_doc(&daemon.dir.join("docs/sub/a.json"), "{}\n");
    let b = write_doc(&daemon.dir.join("docs/sub/b.json"), "{}\n");
    card.register_file(&mut app, &a);
    doc_data(&mut app, "board-0", &dash2, Some(&b));
    assert_eq!(app.recv_file_event_for(&b), mtime_ms(&b));

    doc_data(&mut app, "board-0", &card.dash, None);
    assert!(quiet(&mut app, &b));
    let edited = edit(&b);
    assert_eq!(app.recv_file_event_since(&b, edited), edited);
    assert!(quiet(&mut app, &b), "one file_event for one write");
}

// S25a: S44 with the file in `sub`.
#[test]
fn a_doc_data_in_a_subdirectory_for_a_board_in_the_background_is_answered_at_its_switch() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = card_in_the_background(&daemon, &mut app);
    let stats = write_doc(&daemon.dir.join("docs/sub/stats.json"), "{}\n");

    doc_data(&mut app, "board-1", &card.dash, Some(&stats));
    none_at_once_for(&mut app, &card.other, &[&stats]);
    look_with_none_for(&mut app, &card.other, &[&stats]);

    switch_with_restore_first(&mut app, "board-1", &stats);
    assert_eq!(app.recv_file_event_for(&stats), mtime_ms(&stats));
}

// S28, the state file. A layout makes the save.
#[test]
fn a_data_file_in_a_subdirectory_is_not_in_the_state_file() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (_card, _stats) = card_reading_sub(&daemon, &mut app);

    let viewport = BoardViewport { zoom: 1.25, cx: 10.0, cy: 20.0 };
    app.send(&Msg::Layout { dock: vec![], tiles: vec![], board: Some(viewport), board_id: None });
    daemon.wait_for_state("the layout's viewport", |v| v["boards"][0]["board"]["zoom"] == json!(1.25));
    let state = daemon.state_json().to_string();
    assert!(state.contains("dash.html"), "the doc is in the state file");
    assert!(!state.contains("stats.json") && !state.contains("/sub"), "no trace of the data file: {state}");
}

// S29. `self` leads to the card's own directory: the watch of that directory
// must outlive the data file's registration.
#[test]
fn a_data_path_through_a_link_to_the_doc_directory_leaves_its_watch() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    std::os::unix::fs::symlink(".", daemon.dir.join("docs/self")).unwrap();
    let through = card.beside("self/stats.json");
    doc_data(&mut app, "board-0", &card.dash, Some(&through));
    assert_eq!(app.recv_file_event_for(&through), mtime_ms(&card.stats));

    doc_data(&mut app, "board-0", &card.dash, None);
    assert!(quiet(&mut app, &card.other));
    let edited = edit(&card.other);
    assert_eq!(app.recv_file_event_since(&card.other, edited), edited);
}

/// `<dir>/<name>` made as a link to `target`, and the path of `file` through
/// it, as text: `write_doc` would give the resolved path.
fn through_link(card: &Card, name: &str, target: &Path, file: &str) -> String {
    std::os::unix::fs::symlink(target, card.beside(name)).unwrap();
    card.beside(&format!("{name}/{file}"))
}

// S30a. The negative check is the point here: a forced look would stat the
// file through the link and report it.
#[test]
fn a_data_file_through_a_link_out_of_the_tree_is_seen_only_by_a_look() {
    let away = temp_dir();
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let real = write_doc(&away.join("stats.json"), "{}\n");
    let out = through_link(&card, "out", &away, "stats.json");
    doc_data(&mut app, "board-0", &card.dash, Some(&out));
    assert_eq!(app.recv_file_event_for(&out), mtime_ms(&real), "the registration stands");
    assert!(quiet(&mut app, &out));

    edit(&real);
    assert!(quiet(&mut app, &out), "nothing watches the directory the link leads to");
    let edited = edit(&card.other);
    app.recv_file_event_since(&card.other, edited);
    assert_eq!(app.recv_file_event_for(&out), mtime_ms(&real), "a look stats it");

    let _ = std::fs::remove_dir_all(&away);
}

// S31
#[test]
fn one_write_through_a_link_in_the_tree_is_one_file_event_for_the_path_named() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let card = Card::open(&daemon, &mut app);
    let real = write_doc(&daemon.dir.join("docs/real/stats.json"), "{}\n");
    let named = through_link(&card, "in", Path::new(&real).parent().unwrap(), "stats.json");
    doc_data(&mut app, "board-0", &card.dash, Some(&named));
    assert_eq!(app.recv_file_event_for(&named), mtime_ms(&real));
    assert!(quiet(&mut app, &named));

    let edited = edit(&real);
    assert_eq!(app.recv_file_event_since(&named, edited), edited);
    assert!(quiet(&mut app, &named), "one file_event for one write");
    assert!(none_within(&mut app, Duration::from_millis(200), |m| is_file_event_for(m, &real)), "none for the resolved path");
}

// S26b. The new app names no file: neither registration of the app that
// went is left.
#[test]
fn the_registrations_of_an_app_that_went_are_dropped() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (card, stats) = card_reading_sub(&daemon, &mut app);
    let dash2 = write_doc(&daemon.dir.join("docs/dash2.html"), "<p>dash2</p>\n");
    app.open_on("board-0", &dash2);
    let beside = write_doc(&daemon.dir.join("docs/beside.json"), "{}\n");
    doc_data(&mut app, "board-0", &dash2, Some(&beside));
    assert_eq!(app.recv_file_event_for(&beside), mtime_ms(&beside));

    drop(app);
    let mut app = daemon.connect_app_drained();
    edit(&stats);
    edit(&beside);
    look_with_none_for(&mut app, &card.other, &[&stats, &beside]);
}
