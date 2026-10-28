// #258: a doc whose file keeps changing, with gaps shorter than the 100 ms
// burst window, is reported while the writes go on, not only after they stop.

mod common;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use common::{Conn, LONG, TestDaemon, append_to, is_file_event_for, mtime_ms, quiet, write_doc};
use notify::event::{EventKind, ModifyKind};
use notify::{RecursiveMode, Watcher};
use tarmac_protocol::{self as proto, frame};

const WRITES_FOR: Duration = Duration::from_secs(2);
const WRITE_GAP: Duration = Duration::from_millis(3);

// For a while after a file is made, FSEvents repeats `ItemCreated` on each of
// its writes, and the old debouncer gave each event of a path whose queue
// starts with a create: that hid #258 from the suites. It lasts from 2 s to more
// than 20 s, but some thousands of other new files end it (measured). The doc
// is ready when a write to it is a plain change, as for a doc made long ago.
fn old_doc(daemon: &TestDaemon) -> String {
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

/// The `file_event`s for `doc` that come while `write` runs on another thread.
fn file_events_during(app: &mut Conn, doc: &str, write: impl FnOnce() + Send + 'static) -> usize {
    let done = Arc::new(AtomicBool::new(false));
    let writer = std::thread::spawn({
        let done = done.clone();
        move || {
            write();
            done.store(true, Ordering::SeqCst);
        }
    });
    let mut count = 0;
    app.0.set_read_timeout(Some(Duration::from_millis(20))).unwrap();
    while !done.load(Ordering::SeqCst) {
        if let Ok(payload) = frame::read_sync(&mut app.0)
            && is_file_event_for(&proto::decode(&payload).unwrap(), doc)
            && !done.load(Ordering::SeqCst)
        {
            count += 1;
        }
    }
    writer.join().unwrap();
    count
}

fn for_a_while(mut write: impl FnMut() + Send + 'static) -> impl FnOnce() + Send + 'static {
    move || {
        let start = Instant::now();
        while start.elapsed() < WRITES_FOR {
            write();
            std::thread::sleep(WRITE_GAP);
        }
    }
}

fn assert_steady(count: usize) {
    let most = (WRITES_FOR.as_millis() / 100 + 1) as usize;
    assert!((5..=most).contains(&count), "{count} file_events in {WRITES_FOR:?} of writes, want 5..={most}");
}

#[test]
fn a_doc_appended_with_no_gap_is_reported_while_the_writes_go_on() {
    let daemon = TestDaemon::start();
    let doc = old_doc(&daemon);
    let mut app = daemon.connect_app_drained();
    app.open_on("board-0", &doc);

    let path = doc.clone();
    let count = file_events_during(&mut app, &doc, for_a_while(move || append_to(&path, b"x")));
    eprintln!("append: {count} file_events");
    assert_steady(count);
}

#[test]
fn a_doc_replaced_with_no_gap_is_reported_while_the_writes_go_on() {
    let daemon = TestDaemon::start();
    let doc = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    let mut app = daemon.connect_app_drained();
    app.open_on("board-0", &doc);

    let path = doc.clone();
    let tmp = daemon.dir.join("docs/.y.md.tmp");
    let mut n = 0u64;
    let count = file_events_during(
        &mut app,
        &doc,
        for_a_while(move || {
            n += 1;
            std::fs::write(&tmp, format!("y {n}\n")).unwrap();
            std::fs::rename(&tmp, &path).unwrap();
        }),
    );
    eprintln!("replace: {count} file_events");
    assert_steady(count);
}

// A save shorter than the burst window is read when it is done, not in the
// middle: the app is told one time, of the file as the save left it.
#[test]
fn a_save_in_two_pieces_is_reported_once_when_it_is_done() {
    let daemon = TestDaemon::start();
    let doc = write_doc(&daemon.dir.join("docs/y.md"), "y\n");
    let mut app = daemon.connect_app_drained();
    app.open_on("board-0", &doc);

    append_to(&doc, b"first half\n");
    std::thread::sleep(Duration::from_millis(20));
    append_to(&doc, b"second half\n");
    let saved = mtime_ms(&doc);

    assert_eq!(app.recv_file_event_for(&doc), saved, "the first file_event is of the whole save");
    assert!(quiet(&mut app, &doc), "and it is the only one");
}
