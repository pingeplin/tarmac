use super::*;

fn count(daemon: &Daemon, dir: &Path) -> usize {
    daemon.doc_counts.0.lock().unwrap().get(dir).copied().unwrap_or(0)
}

/// What an open whose watch did not answer gets, from a daemon whose limit
/// is `LIMIT`.
fn cannot_watch(dir: &Path) -> Result<(), String> {
    Err(format!("cannot watch {}: did not answer in {LIMIT:?}", dir.display()))
}

async fn try_close(daemon: &Arc<Daemon>, doc: &Path) -> bool {
    let (daemon, doc) = (daemon.clone(), doc.to_owned());
    answers(async move { daemon.close_doc(&doc).await }).await
}

// 2610.0012 S5b (D9): a walk that is out makes its dir out, and a dir that
// is out is not watched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_dir_whose_repo_does_not_answer_fails_the_open() {
    let tmp = canon_tmp("walk-stuck-new-dir");
    let gone = tmp.join("gone");
    let doc = write_doc(gone.join("b.md"));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::RepoOf, &gone);
    let (source, calls, _unheld) = held_source(&[]);
    let daemon = held(&tmp, source, fs).await;

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, cannot_watch(&gone));
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
    assert!(!registered(&daemon, &doc).await);
    assert_eq!(count(&daemon, &gone), 0);
    assert!(!watched(&daemon, &gone).await);
    assert_eq!(calls.of(Change::Watch, &gone), 0);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S9
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_close_whose_unwatch_does_not_return_answers_at_once() {
    let tmp = canon_tmp("unwatch-stuck");
    let (gone, d) = (tmp.join("gone"), tmp.join("d"));
    let (stuck, open) = (write_doc(gone.join("a.md")), write_doc(d.join("a.md")));
    let doc = write_doc(d.join("b.md"));
    let (fs, _unheld) = stuck_fs();
    let (source, calls, _release) = held_source(&[(Change::Unwatch, &gone)]);
    let daemon = held(&tmp, source, fs).await;
    assert_eq!(try_open(&daemon, &stuck).await, Ok(()));
    assert_eq!(try_open(&daemon, &open).await, Ok(()));

    let before = std::time::Instant::now();
    assert!(try_close(&daemon, &stuck).await);
    assert!(before.elapsed() < LIMIT, "the close waited {:?}", before.elapsed());
    eventually("the held unwatch", || calls.of(Change::Unwatch, &gone) == 1).await;

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert!(before.elapsed() < LIMIT, "the open waited {:?}", before.elapsed());

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S10: the bounded part of the Riskiest assumption.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_watch_that_does_not_return_fails_only_the_opens_that_need_it() {
    let tmp = canon_tmp("watch-stuck");
    let new = tmp.join("new");
    let doc = write_doc(new.join("b.md"));
    let (kept, other) = (write_doc(tmp.join("kept/a.md")), write_doc(tmp.join("other/c.md")));
    let (fs, _unheld) = stuck_fs();
    let (source, calls, release) = held_source(&[(Change::Watch, &new)]);
    let daemon = held(&tmp, source, fs).await;
    assert_eq!(try_open(&daemon, &kept).await, Ok(()));
    assert_eq!(try_open(&daemon, &other).await, Ok(()));

    let opened = std::time::Instant::now();
    let opening = spawn_open(&daemon, &doc);
    eventually("the held watch", || calls.of(Change::Watch, &new) == 1).await;
    let before = std::time::Instant::now();
    assert!(try_close(&daemon, &other).await);
    look_at(&daemon).await;
    assert!(before.elapsed() < LIMIT, "the close and the look waited {:?}", before.elapsed());

    assert_eq!(within(opening).await, cannot_watch(&new));
    assert!(opened.elapsed() < 3 * LIMIT, "the open waited {:?}", opened.elapsed());
    assert!(!registered(&daemon, &doc).await);

    drop(release);
    assert!(!watched(&daemon, &new).await, "the failed open left no count");
    assert_eq!(calls.of(Change::Unwatch, &new), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S11: a dir that is out waits for its call, the close side.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dir_that_is_out_is_unwatched_when_its_call_returns() {
    let tmp = canon_tmp("unwatch-out");
    let gone = tmp.join("gone");
    let (stuck, doc) = (write_doc(gone.join("a.md")), write_doc(tmp.join("d/b.md")));
    let (fs, release) = stuck_fs();
    let (source, calls, _unheld) = held_source(&[]);
    let daemon = held(&tmp, source, fs.clone()).await;
    let mut app = connect_app(&daemon).await;
    assert_eq!(try_open(&daemon, &stuck).await, Ok(()));
    flushed(&mut app, &stuck).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    flushed(&mut app, &doc).await;
    fs.hold(Call::Stamp, &gone);
    look_at(&daemon).await;
    assert_eq!(fs.held(Call::Stamp), 1);

    assert!(try_close(&daemon, &stuck).await);
    assert!(watched(&daemon, &gone).await);
    assert_eq!(calls.of(Change::Unwatch, &gone), 0);

    let changed = change(&doc);
    drop(release);
    assert_eq!(next_change(&mut app).await, (doc, changed));
    eventually("the unwatch", || calls.of(Change::Unwatch, &gone) == 1).await;
    assert!(!watched(&daemon, &gone).await);
    assert_eq!(calls.of(Change::Unwatch, &gone), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S11, the open side: the open's resolve is out, keyed in `gone`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_new_doc_in_a_dir_that_is_out_fails_at_once() {
    let tmp = canon_tmp("watch-out");
    let gone = tmp.join("gone");
    let (stuck, doc) = (write_doc(gone.join("a.md")), write_doc(gone.join("b.md")));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::Resolve, &stuck);
    let (source, calls, _unheld) = held_source(&[]);
    let daemon = held(&tmp, source, fs.clone()).await;
    assert_eq!(try_open(&daemon, &stuck).await, did_not_answer(&daemon, &stuck));

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, cannot_watch(&gone));
    assert!(before.elapsed() < LIMIT, "it waited {:?}", before.elapsed());
    assert_eq!(fs.calls(Call::Resolve), 2, "the doc was resolved");
    assert!(!registered(&daemon, &doc).await);
    assert!(!watched(&daemon, &gone).await);
    assert_eq!(calls.of(Change::Watch, &gone), 0);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S12: the thread compares the count with the watch when it
// comes to the dir, not when it was asked.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reopen_behind_a_pending_unwatch_keeps_its_dir_watched() {
    let tmp = canon_tmp("reopen-pending");
    let (x, d) = (tmp.join("x"), tmp.join("d"));
    let (busy, doc) = (write_doc(x.join("a.md")), write_doc(d.join("a.md")));
    let (fs, _unheld) = stuck_fs();
    let (source, calls, release) = held_source(&[(Change::Unwatch, &x)]);
    // A limit that the release after the poll below cannot miss.
    let daemon = Daemon::with_fs(tmp.join("state.json"), source, Arc::new(Notify::new()), fs, Duration::from_secs(30)).await;
    assert_eq!(try_open(&daemon, &busy).await, Ok(()));
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert!(try_close(&daemon, &busy).await);
    eventually("the held unwatch", || calls.of(Change::Unwatch, &x) == 1).await;
    assert!(try_close(&daemon, &doc).await);

    let reopening = spawn_open(&daemon, &doc);
    eventually("the count of the re-open", || count(&daemon, &d) == 1).await;
    drop(release);
    assert_eq!(within(reopening).await, Ok(()));
    assert!(watched(&daemon, &d).await);
    assert_eq!(calls.of(Change::Unwatch, &d), 0);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S14: the first open released its count, so the second asks
// for the watch again.
#[tokio::test]
async fn an_open_whose_watch_is_refused_fails_each_time_and_wakes_a_look() {
    let tmp = tmp_dir("refused-twice");
    let refused = tmp.join("refused");
    let daemon =
        Daemon::with_source(tmp.join("state.json"), Box::new(RefusesDir(refused.clone())), Arc::new(Notify::new())).await;
    let mut app = connect_app(&daemon).await;
    let kept = write_doc(tmp.join("kept/a.md"));
    open_doc(&daemon, None, &kept).await;
    flushed(&mut app, &kept).await;
    let doc = write_doc(refused.join("b.md"));
    let refusal = format!("cannot watch {}: refused", refused.display());

    let changed = change(&kept);
    let first = daemon.open_doc(None, &doc, "t", None, None, None).await;
    assert_eq!(first.map_err(|e| e.to_string()).err(), Some(refusal.clone()));
    assert_eq!(next_change(&mut app).await, (kept.clone(), changed));

    let second = daemon.open_doc(None, &doc, "t", None, None, None).await;
    assert_eq!(second.map_err(|e| e.to_string()).err(), Some(refusal));
    assert!(!daemon.close_doc(&doc).await, "nothing was registered");

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S16: `watch_loop`'s one permit folds the wakes of the three
// unwatches into one look, or two when one comes during the look.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deleting_a_board_looks_once_or_twice_for_its_unwatches() {
    let tmp = canon_tmp("delete-looks");
    let sentinel = write_doc(tmp.join("s/s.md"));
    let dirs: Vec<PathBuf> = ["a", "b", "c"].iter().map(|d| tmp.join(d)).collect();
    let (fs, _unheld) = stuck_fs();
    let (source, calls, _release) = held_source(&[]);
    let daemon = held(&tmp, source, fs.clone()).await;
    let mut app = connect_app(&daemon).await;
    assert_eq!(try_open(&daemon, &sentinel).await, Ok(()));
    flushed(&mut app, &sentinel).await;
    let other = daemon.boards.lock().await.create();
    daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
    for dir in &dirs {
        open_doc(&daemon, Some(&other), &write_doc(dir.join("1.md"))).await;
        flushed(&mut app, &sentinel).await;
    }
    let reads = fs.calls(Call::Stamp);

    assert!(daemon.delete_board(&other).await);
    for dir in &dirs {
        assert!(!watched(&daemon, dir).await);
        assert_eq!(calls.of(Change::Unwatch, dir), 1);
    }
    eventually("a look", || fs.calls(Call::Stamp) > reads).await;
    // Nothing to wait for: the time in which a third look would come.
    tokio::time::sleep(4 * crate::watch::BURST).await;
    let looks = fs.calls(Call::Stamp) - reads;
    assert!((1..=2).contains(&looks), "{looks} looks");

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S21: `Daemon::new` sends the startup watches and does not
// wait for them.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restart_does_not_wait_for_its_watches() {
    let tmp = canon_tmp("restart-held");
    let d = tmp.join("d");
    let doc = write_doc(d.join("a.md"));
    std::fs::write(tmp.join("state.json"), state_with_docs(&[&doc])).unwrap();
    let (fs, _unheld) = stuck_fs();
    let (source, calls, release) = held_source(&[(Change::Watch, &d)]);

    let before = std::time::Instant::now();
    let building = tokio::spawn({
        let tmp = tmp.clone();
        async move { held(&tmp, source, fs).await }
    });
    let daemon = tokio::time::timeout(Duration::from_secs(2), building).await.expect("a daemon").unwrap();
    assert!(before.elapsed() < LIMIT, "it waited {:?}", before.elapsed());
    assert!(registered(&daemon, &doc).await);

    drop(release);
    assert!(watched(&daemon, &d).await);
    assert_eq!(calls.of(Change::Watch, &d), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// One `Retry` reconciles every dir that waits for it. A key that is a
// dir (here the resolve of an open of a dir) makes it and its parent out
// at once, and so its return sends one `Retry` for the two.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retry_unwatches_every_dir_that_was_skipped() {
    let tmp = canon_tmp("retry-both");
    let (outer, inner) = (tmp.join("p"), tmp.join("p/q"));
    let docs = [write_doc(outer.join("a.md")), write_doc(inner.join("b.md"))];
    let (fs, release) = stuck_fs();
    let (source, calls, _unheld) = held_source(&[]);
    let daemon = held(&tmp, source, fs.clone()).await;
    for doc in &docs {
        assert_eq!(try_open(&daemon, doc).await, Ok(()));
    }
    fs.hold(Call::Resolve, &inner);
    assert!(try_open(&daemon, &inner).await.is_err());
    assert!(daemon.gate().is_out_dir(&outer) && daemon.gate().is_out_dir(&inner));

    for doc in &docs {
        assert!(try_close(&daemon, doc).await);
    }
    assert!(watched(&daemon, &outer).await && watched(&daemon, &inner).await, "both are skipped");

    drop(release);
    eventually("both unwatches", || {
        calls.of(Change::Unwatch, &outer) == 1 && calls.of(Change::Unwatch, &inner) == 1
    })
    .await;

    let _ = std::fs::remove_dir_all(&tmp);
}

/// Records each call; each unwatch fails.
struct UnwatchFails(Arc<SourceCalls>);

impl WakeSource for UnwatchFails {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        self.0.0.lock().unwrap().push((Change::Watch, dir.to_owned()));
        Ok(())
    }

    fn unwatch(&mut self, dir: &Path) -> anyhow::Result<()> {
        self.0.0.lock().unwrap().push((Change::Unwatch, dir.to_owned()));
        anyhow::bail!("watch not found")
    }
}

// notify takes the dir out of its stream before it fails most unwatches
// (`FsEventWatcher::remove_path`): a dir that is kept as watched would
// never be watched again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_dir_whose_unwatch_failed_is_watched_by_the_next_open() {
    let tmp = canon_tmp("unwatch-fails");
    let d = tmp.join("d");
    let doc = write_doc(d.join("a.md"));
    let calls = Arc::new(SourceCalls::default());
    let (fs, _unheld) = stuck_fs();
    let daemon = held(&tmp, Box::new(UnwatchFails(calls.clone())), fs).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert!(try_close(&daemon, &doc).await);
    assert!(!watched(&daemon, &d).await);
    assert_eq!(calls.of(Change::Unwatch, &d), 1);

    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert_eq!(calls.of(Change::Watch, &d), 2);

    let _ = std::fs::remove_dir_all(&tmp);
}

struct Panics;

impl WakeSource for Panics {
    fn watch(&mut self, _: &Path) -> anyhow::Result<()> {
        panic!("the source panics")
    }

    fn unwatch(&mut self, _: &Path) -> anyhow::Result<()> {
        Ok(())
    }
}

#[derive(Clone, Default)]
struct Log(Arc<std::sync::Mutex<Vec<u8>>>);

impl std::io::Write for Log {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

// After a panic every first open fails: the log is the one place that
// says why. The watcher thread has no subscriber of its own, so this test
// sets the global one; no other test of this binary sets one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_watcher_thread_that_panics_logs_an_error() {
    let log = Log::default();
    let writer = log.clone();
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_writer(move || writer.clone())
        .with_max_level(tracing::Level::ERROR)
        .init();
    let tmp = canon_tmp("watcher-panics");
    let doc = write_doc(tmp.join("d/a.md"));
    let (fs, _unheld) = stuck_fs();
    let daemon = held(&tmp, Box::new(Panics), fs).await;

    assert!(try_open(&daemon, &doc).await.is_err());
    let logged = || String::from_utf8_lossy(&log.0.lock().unwrap()).contains("the watcher thread panicked");
    eventually("the error", logged).await;

    let _ = std::fs::remove_dir_all(&tmp);
}
