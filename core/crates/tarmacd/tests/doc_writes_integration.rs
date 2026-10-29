// #258: a doc whose file keeps changing, with gaps shorter than the 100 ms
// burst window, is reported while the writes go on, not only after they stop.

mod common;

use std::sync::mpsc;
use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon, append_to, is_file_event_for, mtime_ms, none_within, quiet, write_doc};
use notify::event::{EventKind, ModifyKind};
use notify::{RecursiveMode, Watcher};

const WRITES_FOR: Duration = Duration::from_secs(2);
const WRITE_GAP: Duration = Duration::from_millis(3);

// FSEvents repeats `ItemCreated` on each write to a new file until enough other
// creates on the volume clear it, and the old debouncer gave each such event:
// that hid #258 from the suites.
fn settled_doc(daemon: &TestDaemon) -> String {
    let doc = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    let churn = daemon.dir.join("churn");
    std::fs::create_dir_all(&churn).unwrap();
    let (tx, rx) = mpsc::channel();
    let mut watcher = notify::recommended_watcher(tx).unwrap();
    watcher.watch(&daemon.dir.join("docs"), RecursiveMode::NonRecursive).unwrap();
    let deadline = Instant::now() + LONG;
    for round in 0.. {
        for i in 0..8000 {
            std::fs::write(churn.join(format!("{round}-{i}")), "").unwrap();
        }
        while rx.try_recv().is_ok() {}
        append_to(&doc, b"y\n");
        std::thread::sleep(Duration::from_millis(200));
        let kinds: Vec<EventKind> = rx.try_iter().filter_map(Result::ok).map(|e| e.kind).collect();
        if kinds.iter().any(|k| matches!(k, EventKind::Modify(ModifyKind::Data(_))))
            && !kinds.iter().any(|k| matches!(k, EventKind::Create(_)))
        {
            break;
        }
        assert!(Instant::now() < deadline, "FSEvents still takes {doc} for a new file: {kinds:?}");
    }
    doc
}

fn opened(daemon: &TestDaemon, doc: &str) -> Conn {
    let mut app = daemon.connect_app_drained();
    app.open_on("board-0", doc);
    app
}

/// Runs `write` again and again for `WRITES_FOR`, and asserts that the
/// `file_event`s for `doc` meanwhile are steady: some, and at most one per 100 ms.
fn assert_steady_while(app: &mut Conn, doc: &str, mut write: impl FnMut() + Send + 'static) {
    let writer = std::thread::spawn(move || {
        let start = Instant::now();
        while start.elapsed() < WRITES_FOR {
            write();
            std::thread::sleep(WRITE_GAP);
        }
    });
    let mut count = 0;
    none_within(app, WRITES_FOR, |m| {
        count += usize::from(is_file_event_for(m, doc));
        false
    });
    writer.join().unwrap();
    let most = (WRITES_FOR.as_millis() / 100 + 1) as usize;
    assert!((5..=most).contains(&count), "{count} file_events in {WRITES_FOR:?} of writes, want 5..={most}");
}

#[test]
fn a_doc_appended_with_no_gap_is_reported_while_the_writes_go_on() {
    let daemon = TestDaemon::start();
    let doc = settled_doc(&daemon);
    let mut app = opened(&daemon, &doc);

    let path = doc.clone();
    assert_steady_while(&mut app, &doc, move || append_to(&path, b"x"));
}

#[test]
fn a_doc_replaced_with_no_gap_is_reported_while_the_writes_go_on() {
    let daemon = TestDaemon::start();
    let doc = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    let mut app = opened(&daemon, &doc);

    let path = doc.clone();
    let tmp = daemon.dir.join("docs/.y.md.tmp");
    let mut n = 0u64;
    assert_steady_while(&mut app, &doc, move || {
        n += 1;
        std::fs::write(&tmp, format!("y {n}\n")).unwrap();
        std::fs::rename(&tmp, &path).unwrap();
    });
}

// A save shorter than the burst window is read when it is done, not in the
// middle: the app is told one time, of the file as the save left it.
#[test]
fn a_save_in_two_pieces_is_reported_once_when_it_is_done() {
    let daemon = TestDaemon::start();
    let doc = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    let mut app = opened(&daemon, &doc);

    for _ in 0..5 {
        append_to(&doc, b"first half\n");
        let started = mtime_ms(&doc);
        std::thread::sleep(Duration::from_millis(20));
        append_to(&doc, b"second half\n");
        let saved = mtime_ms(&doc);
        // A stalled runner can stretch the 20 ms past the burst window
        // (`watch::BURST`, 100 ms); then the first half is a save of its own.
        if saved - started >= 50 {
            while !quiet(&mut app, &doc) {}
            continue;
        }
        assert_eq!(app.recv_file_event_for(&doc), saved, "the first file_event is of the whole save");
        assert!(quiet(&mut app, &doc), "and it is the only one");
        return;
    }
    panic!("no save of two pieces came within half the burst window in 5 tries");
}
