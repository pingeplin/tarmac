use super::*;

/// A daemon that its watcher never wakes, with no app.
async fn silent(tag: &str) -> (PathBuf, Arc<Daemon>) {
    let tmp = tmp_dir(tag);
    let daemon =
        Daemon::with_source(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new())).await;
    (tmp, daemon)
}

/// `silent`, and the pushes to its app.
async fn silent_daemon(tag: &str) -> (PathBuf, Arc<Daemon>, mpsc::Receiver<Msg>) {
    let (tmp, daemon) = silent(tag).await;
    let app = connect_app(&daemon).await;
    (tmp, daemon, app)
}

/// Waits until the state file has the doc with `want` as its
/// `last_changed_ms`. A test waits for the save of the open (`None`)
/// first: a save comes 150 ms after it was asked for, so the one that the
/// open asked for would carry a later record too.
async fn wait_for_saved(tmp: &Path, doc: &Path, want: Option<u64>) {
    let saved = || {
        let boards = crate::persist::load(&tmp.join("state.json"));
        boards.active_registry().docs.get(doc).map(|info| info.last_changed_ms)
    };
    for _ in 0..200 {
        if saved() == Some(want) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("the state file never had {want:?}, it has {:?}", saved());
}

// #253: an unwatch restarts the FSEvents stream, and the restart loses the
// events that the stream has not delivered yet. So the watcher thread
// wakes a look after the unwatch; here no other wake comes at all.
#[tokio::test]
async fn a_close_reports_a_change_that_no_wake_told_of() {
    let (tmp, daemon, mut app) = silent_daemon("close-reports").await;
    let kept = write_doc(tmp.join("kept/a.md"));
    let gone = write_doc(tmp.join("gone/b.md"));
    open_doc(&daemon, None, &kept).await;
    flushed(&mut app, &kept).await;
    open_doc(&daemon, None, &gone).await;
    flushed(&mut app, &gone).await;

    let changed = change(&kept);
    assert!(daemon.close_doc(&gone).await);
    assert_eq!(next_change(&mut app).await, (kept, changed));

    let _ = std::fs::remove_dir_all(&tmp);
}

// The same for a watch: the first doc of a directory.
#[tokio::test]
async fn an_open_reports_a_change_that_no_wake_told_of() {
    let (tmp, daemon, mut app) = silent_daemon("open-reports").await;
    let kept = write_doc(tmp.join("kept/a.md"));
    let new = write_doc(tmp.join("new/b.md"));
    open_doc(&daemon, None, &kept).await;

    let changed = change(&kept);
    open_doc(&daemon, None, &new).await;
    assert_eq!(file_events(&mut app), vec![(kept, changed)], "and nothing for the doc that was opened");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn a_wake_reports_a_change() {
    let (tmp, daemon, mut app) = silent_daemon("wake-reports").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;

    let changed = change(&doc);
    tokio::task::yield_now().await;
    assert_eq!(file_events(&mut app), vec![], "nothing looked at the doc yet");

    daemon.wake.notify_one();
    assert_eq!(next_file_event(&mut app).await, changed);

    let _ = std::fs::remove_dir_all(&tmp);
}

// A wake can come from any file of a watched directory, in the middle of a
// doc's own burst. docs/protocol.md gives a doc one file_event for a burst.
#[tokio::test]
async fn a_look_comes_no_sooner_than_the_burst_window_after_the_one_before() {
    let (tmp, daemon, mut app) = silent_daemon("burst").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;

    // Taken before the first look: the wait starts when that look ends.
    let before = std::time::Instant::now();
    let first = change(&doc);
    daemon.wake.notify_one();
    assert_eq!(next_file_event(&mut app).await, first);

    let second = change(&doc);
    daemon.wake.notify_one();
    assert_eq!(next_file_event(&mut app).await, second);
    assert!(before.elapsed() >= crate::watch::BURST, "the second look came after {:?}", before.elapsed());

    let _ = std::fs::remove_dir_all(&tmp);
}

// A look with no app records the change, so a restart keeps its time, and
// holds it for the look that has an app to tell.
#[tokio::test]
async fn a_look_with_no_app_records_the_change_and_holds_it_to_be_told() {
    let (tmp, daemon) = silent("no-app").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;
    wait_for_saved(&tmp, &doc, None).await;

    let changed = change(&doc);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(last_changed(&daemon, &doc).await, Some(changed));
    wait_for_saved(&tmp, &doc, Some(changed)).await;

    let mut app = connect_app(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)]);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![], "it is told one time");

    let _ = std::fs::remove_dir_all(&tmp);
}

// A save writes the state file. With a doc in that directory, a look that
// asked for a save each time would wake itself for ever.
#[tokio::test]
async fn a_look_that_records_nothing_asks_for_no_save() {
    let (tmp, daemon) = silent("no-save").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;
    wait_for_saved(&tmp, &doc, None).await;

    let changed = change(&doc);
    crate::docs::report_changes(&daemon).await;
    wait_for_saved(&tmp, &doc, Some(changed)).await;
    let saved_at = mtime(&tmp.join("state.json"));

    // The change is held, since there is no app, and is tried at each look.
    crate::docs::report_changes(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(mtime(&tmp.join("state.json")), saved_at);

    let _ = std::fs::remove_dir_all(&tmp);
}

// The record follows the file also while nobody is told: a file that is
// changed and put back is recorded as it is.
#[tokio::test]
async fn a_change_that_went_back_with_no_app_is_recorded_as_the_file_is() {
    let (tmp, daemon) = silent("no-app-back").await;
    let doc = write_doc(tmp.join("d/a.md"));
    let first = mtime(&doc);
    open_doc(&daemon, None, &doc).await;

    let changed = change(&doc);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(last_changed(&daemon, &doc).await, Some(changed));

    set_mtime(&doc, first);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(last_changed(&daemon, &doc).await, Some(crate::boards::epoch_ms(first)));

    let mut app = connect_app(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc, crate::boards::epoch_ms(first))]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// An app that goes away between the look and the push: its frame is
// dropped, and the change is held for the next app.
#[tokio::test]
async fn a_change_whose_app_went_away_is_told_to_the_next_app() {
    let (tmp, daemon, app) = silent_daemon("app-gone").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;

    drop(app);
    let changed = change(&doc);
    crate::docs::report_changes(&daemon).await;

    let mut app = connect_app(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// The hold is for the board whose look took the change. The active board
// can be another one by the time the push fails.
#[tokio::test]
async fn a_change_is_held_for_its_board_when_another_board_is_active() {
    let (tmp, daemon) = silent("held-board").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;
    let changed = change(&doc);
    daemon.look(|_| vec![doc.clone()], |boards, now| boards.active_registry_mut().take_changes(now)).await;

    let other = daemon.boards.lock().await.create();
    open_doc(&daemon, Some(&other), &doc).await;
    crate::docs::push_file_event(&daemon, crate::boards::DEFAULT_BOARD_ID, &doc, changed).await;

    let mut app = connect_app(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![], "the board that is active was not the one");
    daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// A refresh with no app is held like a look's change, and a refresh tells
// what was held: the look after it has nothing left.
#[tokio::test]
async fn a_refresh_holds_what_reached_no_app_and_tells_what_was_held() {
    let (tmp, daemon) = silent("refresh-held").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;

    let changed = change(&doc);
    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    let mut app = connect_app(&daemon).await;
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)], "the refresh was held");

    drop(app);
    let again = change(&doc);
    crate::docs::report_changes(&daemon).await;
    let mut app = connect_app(&daemon).await;
    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    assert_eq!(file_events(&mut app), vec![(doc.clone(), again)]);
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![], "the refresh told it");

    let _ = std::fs::remove_dir_all(&tmp);
}

// A save that replaces the file by one with the same mtime and length.
#[tokio::test]
async fn a_file_that_is_replaced_with_the_same_mtime_and_length_is_a_change() {
    let (tmp, daemon, mut app) = silent_daemon("replaced").await;
    let doc = write_doc(tmp.join("d/a.md"));
    let kept = mtime(&doc);
    open_doc(&daemon, None, &doc).await;

    let new = tmp.join("d/a.md.new");
    std::fs::write(&new, "cod").unwrap();
    set_mtime(&new, kept);
    std::fs::rename(&new, &doc).unwrap();
    crate::docs::report_changes(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc, crate::boards::epoch_ms(kept))]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// `Daemon::look` reads the files with no `boards` lock held. If two looks
// ran at once, one that read a doc before its change would apply that
// reading after the other recorded the change. Each round starts a look
// at every doc, waits a part of the time that its reads take, then
// changes one doc and records the change with a second look. The doc goes
// round because its place in the read order is fixed for a process.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_reading_is_never_taken_after_a_newer_one() {
    let (tmp, daemon, mut app) = silent_daemon("one-look").await;
    // Its pushes are not what is under test, and a push waits when 16 are unread.
    tokio::spawn(async move { while app.recv().await.is_some() {} });
    let docs: Vec<PathBuf> = (0..200).map(|i| write_doc(tmp.join(format!("d/{i}.md")))).collect();
    for doc in &docs {
        open_doc(&daemon, None, doc).await;
    }

    for round in 0..400 {
        let doc = &docs[round % docs.len()];
        let look = tokio::spawn({
            let daemon = daemon.clone();
            async move { crate::docs::report_changes(&daemon).await }
        });
        let into_the_reads = std::time::Instant::now() + Duration::from_micros(round as u64 % 40 * 10);
        while std::time::Instant::now() < into_the_reads {
            std::hint::spin_loop();
        }
        let changed = change(doc);
        assert!(crate::docs::stat_and_push(&daemon, doc).await);
        look.await.unwrap();
        assert_eq!(last_changed(&daemon, doc).await, Some(changed), "round {round}");
    }

    let _ = std::fs::remove_dir_all(&tmp);
}

// doc_refresh, S21: it delivers a change that the daemon has not seen.
#[tokio::test]
async fn a_refresh_reports_a_change_that_no_wake_told_of() {
    let (tmp, daemon, mut app) = silent_daemon("refresh-unseen").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;

    let changed = change(&doc);
    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)]);
    assert_eq!(last_changed(&daemon, &doc).await, Some(changed));

    let _ = std::fs::remove_dir_all(&tmp);
}

// doc_refresh, S22: it stats the file. A handler that answers from the
// recorded `last_changed_ms`, and stats only when there is none, passes
// every test whose record is empty or agrees with the file. Here the record
// is there and is old.
#[tokio::test]
async fn a_refresh_stats_the_file_and_does_not_replay_what_is_recorded() {
    let (tmp, daemon, mut app) = silent_daemon("refresh-restats").await;
    let doc = write_doc(tmp.join("d/a.md"));
    open_doc(&daemon, None, &doc).await;
    wait_for_saved(&tmp, &doc, None).await;
    let first = change(&doc);
    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    assert_eq!(file_events(&mut app), vec![(doc.clone(), first)]);
    wait_for_saved(&tmp, &doc, Some(first)).await;

    let second = change(&doc);
    assert_ne!(second, first);
    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    assert_eq!(file_events(&mut app), vec![(doc.clone(), second)], "what the file says now");
    assert_eq!(last_changed(&daemon, &doc).await, Some(second), "recorded, not only announced");
    wait_for_saved(&tmp, &doc, Some(second)).await;

    // The refresh took the file as seen: a look after it has nothing to tell.
    daemon.wake.notify_one();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(file_events(&mut app), vec![]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// notify restarts its stream also for a watch that fails.
#[tokio::test]
async fn an_open_that_cannot_watch_reports_a_change_too() {
    let tmp = tmp_dir("refused-reports");
    let refused = tmp.join("refused");
    let daemon =
        Daemon::with_source(tmp.join("state.json"), Box::new(RefusesDir(refused.clone())), Arc::new(Notify::new())).await;
    let mut app = connect_app(&daemon).await;
    let kept = write_doc(tmp.join("kept/a.md"));
    open_doc(&daemon, None, &kept).await;
    flushed(&mut app, &kept).await;

    let changed = change(&kept);
    assert!(daemon.open_doc(None, &write_doc(refused.join("b.md")), "t", None, None, None).await.is_err());
    assert_eq!(next_change(&mut app).await, (kept, changed));

    let _ = std::fs::remove_dir_all(&tmp);
}
