use super::*;

fn docs_opened(app: &mut mpsc::Receiver<Msg>) -> Vec<PathBuf> {
    let opened = |msg| match msg {
        Msg::DocOpened(entry) => Some(PathBuf::from(entry.path)),
        _ => None,
    };
    pushed(app).into_iter().filter_map(opened).collect()
}

/// The reading of one look at `doc`.
async fn look_at_doc(daemon: &Arc<Daemon>, doc: &Path) -> HashMap<PathBuf, Option<FileStamp>> {
    let (daemon, doc) = (daemon.clone(), doc.to_owned());
    answers(async move { daemon.look(|_| vec![doc], |_, now| now.clone()).await }).await
}

// 2610.0012 S1
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_whose_path_does_not_answer_fails_in_its_limit() {
    let tmp = canon_tmp("open-stuck");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    let daemon = gated(&tmp, fs.clone()).await;

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
    assert!(!registered(&daemon, &doc).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S2
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_open_of_a_path_that_is_out_fails_at_once_with_no_call() {
    let tmp = canon_tmp("open-stuck-again");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
    assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
    assert_eq!(fs.calls(Call::Resolve), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S3
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_answers_while_another_open_waits_for_its_path() {
    let tmp = canon_tmp("open-beside-stuck");
    let stuck = write_doc(tmp.join("gone/a.md"));
    let doc = write_doc(tmp.join("d/b.md"));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    let daemon = gated(&tmp, fs.clone()).await;
    let mut app = connect_app(&daemon).await;

    let stuck_open = tokio::spawn({
        let (daemon, stuck) = (daemon.clone(), stuck.to_str().unwrap().to_owned());
        async move { crate::docs::handle_open(&daemon, &stuck, "cli", None, None).await }
    });
    eventually("the held resolve", || fs.held(Call::Resolve) == 1).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert_eq!(docs_opened(&mut app), vec![doc]);
    assert_eq!(stuck_open.await.unwrap(), did_not_answer(&daemon, &stuck));

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S4: the caller has had its error, and runs the open again.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_that_did_not_answer_is_not_finished_when_its_call_returns() {
    let tmp = canon_tmp("open-not-late");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    let daemon = gated(&tmp, fs.clone()).await;
    let mut app = connect_app(&daemon).await;
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));

    drop(release);
    eventually("the return of the resolve", || !daemon.gate().is_out_dir(&tmp.join("gone"))).await;
    assert!(!registered(&daemon, &doc).await);
    assert_eq!(docs_opened(&mut app), Vec::<PathBuf>::new());

    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert_eq!(fs.calls(Call::Resolve), 2);
    assert!(registered(&daemon, &doc).await);
    assert_eq!(docs_opened(&mut app), vec![doc]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S7
#[tokio::test]
async fn an_open_answers_a_missing_path_a_directory_and_a_file_as_before() {
    let tmp = canon_tmp("open-texts");
    let daemon = on_source(tmp.join("state.json"), Silent).await;
    let missing = tmp.join("missing.md");
    let dir = tmp.join("dir");
    std::fs::create_dir_all(&dir).unwrap();
    let doc = write_doc(tmp.join("d/a.md"));

    assert_eq!(
        try_open(&daemon, &missing).await,
        Err(format!("cannot open {}: No such file or directory (os error 2)", missing.display()))
    );
    assert_eq!(try_open(&daemon, &dir).await, Err(format!("not a regular file: {}", dir.display())));
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert!(registered(&daemon, &doc).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S8: an open and a look of one path share the call that is
// out, the open first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_look_does_not_read_a_path_whose_open_is_out() {
    let tmp = canon_tmp("open-then-look");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    fs.hold(Call::Resolve, &tmp.join("gone"));
    fs.hold(Call::Stamp, &tmp.join("gone"));

    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
    let before = std::time::Instant::now();
    assert_eq!(look_at_doc(&daemon, &doc).await, HashMap::new());
    assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
    assert_eq!(fs.held(Call::Resolve) + fs.held(Call::Stamp), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S8: the look first.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_does_not_resolve_a_path_whose_look_is_out() {
    let tmp = canon_tmp("look-then-open");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    fs.hold(Call::Resolve, &tmp.join("gone"));
    fs.hold(Call::Stamp, &tmp.join("gone"));
    assert_eq!(look_at_doc(&daemon, &doc).await, HashMap::new());
    let resolves = fs.calls(Call::Resolve);

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
    assert!(before.elapsed() < LIMIT, "it waited {:?} for a call that is out", before.elapsed());
    assert_eq!(fs.calls(Call::Resolve), resolves);

    let _ = std::fs::remove_dir_all(&tmp);
}

/// A temp dir in a repo, with a doc whose open had its dir watched.
async fn in_a_repo(tag: &str) -> (PathBuf, PathBuf, Arc<Daemon>, Arc<StuckFs>, std::sync::mpsc::Sender<()>) {
    let tmp = canon_tmp(tag);
    std::fs::create_dir_all(tmp.join(".git")).unwrap();
    let open = write_doc(tmp.join("d/a.md"));
    let (fs, release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(try_open(&daemon, &open).await, Ok(()));
    assert!(repo_of(&daemon, &open).await.0.is_some(), "the doc is in a repo");
    (tmp, open, daemon, fs, release)
}

// 2610.0012 S5
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_doc_whose_repo_does_not_answer_opens_with_no_repo() {
    let (tmp, _, daemon, fs, _release) = in_a_repo("walk-stuck").await;
    let doc = write_doc(tmp.join("d/b.md"));
    fs.hold(Call::RepoOf, &doc);

    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
    assert_eq!(repo_of(&daemon, &doc).await, (None, None, None));

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S6: the next startup fills a missing repo in, not a re-open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reopen_does_not_look_for_the_repo_again() {
    let (tmp, open, daemon, fs, release) = in_a_repo("walk-once").await;
    let repo = repo_of(&daemon, &open).await;
    let walks = fs.calls(Call::RepoOf);
    assert_eq!(try_open(&daemon, &open).await, Ok(()));
    assert_eq!(fs.calls(Call::RepoOf), walks);
    assert_eq!(repo_of(&daemon, &open).await, repo);

    let doc = write_doc(tmp.join("d/b.md"));
    fs.hold(Call::RepoOf, &doc);
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    drop(release);
    eventually("the return of the walk", || !daemon.gate().is_out_dir(&tmp.join("d"))).await;
    let walks = fs.calls(Call::RepoOf);
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    assert_eq!(fs.calls(Call::RepoOf), walks);
    assert_eq!(repo_of(&daemon, &doc).await, (None, None, None));

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S8b: `returned` wakes the daemon, and the look reads what no
// wake told of.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_that_returns_after_its_limit_wakes_a_look() {
    let (tmp, daemon, mut app, stuck, release) = stuck_daemon("returned-wakes").await;
    let doc = write_doc(tmp.join("d/b.md"));
    open_doc(&daemon, None, &doc).await;
    stuck.hold(Call::Stamp, &tmp.join("gone"));
    look_at(&daemon).await;
    assert_eq!(stuck.held(Call::Stamp), 1);

    let changed = change(&doc);
    drop(release);
    assert_eq!(next_file_event(&mut app).await, changed);

    let _ = std::fs::remove_dir_all(&tmp);
}

// An open's call, and a look's on each of its two steps.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn each_call_that_returns_after_its_limit_calls_returned() {
    let tmp = tmp_dir("returned-each");
    let docs: Vec<PathBuf> = (0..3).map(|i| write_doc(tmp.join(format!("gone/{i}.md")))).collect();
    let (fs, release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    fs.hold(Call::Stamp, &tmp.join("gone"));
    let returned = Arc::new(AtomicU32::new(0));
    let gate = Arc::new(PathGate::new(fs, LIMIT, {
        let returned = returned.clone();
        Arc::new(move || {
            returned.fetch_add(1, Ordering::SeqCst);
        })
    }));

    let (resolving, key) = (gate.clone(), docs[0].clone());
    let resolved = answers(async move {
        let raw = key.clone();
        resolving.run(&key, move |fs| fs.resolve(&raw)).await
    });
    assert!(resolved.await.is_err());
    let (reading, paths) = (gate.clone(), docs[1..].to_vec());
    assert_eq!(answers(async move { reading.stamps(paths).await }).await, HashMap::new());
    assert_eq!(returned.load(Ordering::SeqCst), 0);

    drop(release);
    eventually("three returns", || returned.load(Ordering::SeqCst) == 3).await;
    assert!(!gate.is_out_dir(&tmp.join("gone")));

    let _ = std::fs::remove_dir_all(&tmp);
}

// One call on a key at a time: a second caller does not start a thread
// of its own on a path that does not answer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_opens_of_a_path_that_does_not_answer_make_one_call() {
    let tmp = canon_tmp("open-twice-at-once");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("gone"));
    let daemon = gated(&tmp, fs.clone()).await;

    let before = std::time::Instant::now();
    let opens = [spawn_open(&daemon, &doc), spawn_open(&daemon, &doc)];
    for open in opens {
        assert_eq!(open.await.unwrap(), did_not_answer(&daemon, &doc));
    }
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
    assert_eq!(fs.calls(Call::Resolve), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_open_during_a_look_at_its_path_makes_no_call_of_its_own() {
    let tmp = canon_tmp("open-during-look");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, _release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    fs.hold(Call::Resolve, &tmp.join("gone"));
    fs.hold(Call::Stamp, &tmp.join("gone"));

    let look = tokio::spawn({
        let (daemon, doc) = (daemon.clone(), doc.clone());
        async move { daemon.look(|_| vec![doc], |_, now| now.clone()).await }
    });
    eventually("the held read", || fs.held(Call::Stamp) == 1).await;
    let before = std::time::Instant::now();
    assert_eq!(try_open(&daemon, &doc).await, did_not_answer(&daemon, &doc));
    assert!(before.elapsed() < 3 * LIMIT, "it waited {:?}", before.elapsed());
    assert_eq!(look.await.unwrap(), HashMap::new());
    assert_eq!(fs.held(Call::Resolve) + fs.held(Call::Stamp), 1);

    let _ = std::fs::remove_dir_all(&tmp);
}

// The second caller waits for the call there, then makes its own.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_open_of_a_path_that_answers_in_time_succeeds_too() {
    let tmp = canon_tmp("open-twice-healthy");
    let doc = write_doc(tmp.join("d/a.md"));
    let (fs, release) = stuck_fs();
    fs.hold(Call::Resolve, &tmp.join("d"));
    let daemon = gated(&tmp, fs.clone()).await;

    let first = spawn_open(&daemon, &doc);
    eventually("the held resolve", || fs.held(Call::Resolve) == 1).await;
    let second = spawn_open(&daemon, &doc);
    // Time for the second open to reach the call of the first, and less
    // than the limit that it waits for it.
    tokio::time::sleep(LIMIT / 4).await;
    assert!(!second.is_finished(), "the second open did not wait for the first");
    drop(release);
    assert_eq!(first.await.unwrap(), Ok(()));
    assert_eq!(second.await.unwrap(), Ok(()));
    assert_eq!(fs.calls(Call::Resolve), 2);

    let _ = std::fs::remove_dir_all(&tmp);
}

// #280: the waiter's own call starts with little of its limit left. It is
// slow, not stuck, so the caller after it waits for it as for any call.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_call_left_before_a_full_limit_does_not_fail_the_next_caller_at_once() {
    let tmp = tmp_dir("left-early");
    let doc = write_doc(tmp.join("d/a.md"));
    let (stuck, release) = stuck_fs();
    let returned = Arc::new(AtomicU32::new(0));
    // Long enough that a loaded runner reaches each step in its time.
    let limit = Duration::from_secs(1);
    let reader = Arc::new(PathGate::new(stuck.clone(), limit, {
        let returned = returned.clone();
        Arc::new(move || {
            returned.fetch_add(1, Ordering::SeqCst);
        })
    }));
    stuck.hold(Call::Stamp, &tmp.join("d"));
    let run = || {
        let (reader, doc) = (reader.clone(), doc.clone());
        tokio::spawn(async move { reader.run(&doc.clone(), move |fs| fs.stamp(&doc)).await })
    };

    let first = run();
    eventually("the first call", || stuck.held(Call::Stamp) == 1).await;
    let waiter = run();
    tokio::time::sleep(limit * 7 / 10).await;
    release.send(()).unwrap();
    eventually("the waiter's own call", || stuck.held(Call::Stamp) == 2).await;
    assert!(first.await.unwrap().is_ok());
    assert!(waiter.await.unwrap().is_err());

    let after = run();
    // Time for it to reach the waiter's call, well before that call has
    // had a full limit.
    tokio::time::sleep(limit / 5).await;
    release.send(()).unwrap();
    release.send(()).unwrap();
    assert_eq!(within(after).await.ok(), Some(crate::reader::stamp(&doc)));
    eventually("the return of the call the waiter left", || returned.load(Ordering::SeqCst) == 1).await;

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_call_that_panics_after_its_limit_ends_its_key() {
    let tmp = tmp_dir("panics");
    let doc = write_doc(tmp.join("gone/a.md"));
    let (fs, release) = stuck_fs();
    fs.hold(Call::Stamp, &tmp.join("gone"));
    let returned = Arc::new(AtomicU32::new(0));
    let gate = Arc::new(PathGate::new(fs, LIMIT, {
        let returned = returned.clone();
        Arc::new(move || {
            returned.fetch_add(1, Ordering::SeqCst);
        })
    }));

    let (calling, key) = (gate.clone(), doc.clone());
    let ran = answers(async move {
        let path = key.clone();
        calling
            .run(&key, move |fs: &dyn PathFs| -> Option<FileStamp> {
                fs.stamp(&path);
                panic!("the call panics")
            })
            .await
    });
    assert!(ran.await.is_err());

    drop(release);
    eventually("the end of the call", || returned.load(Ordering::SeqCst) == 1).await;
    assert!(!gate.is_out_dir(&tmp.join("gone")));
    let (calling, key) = (gate.clone(), doc.clone());
    let again = answers(async move {
        let path = key.clone();
        calling.run(&key, move |fs| fs.stamp(&path)).await
    });
    assert_eq!(again.await.unwrap(), crate::reader::stamp(&doc));

    let _ = std::fs::remove_dir_all(&tmp);
}

// The open reads the doc's stamp before it registers the doc. In a dir
// that is already watched no look follows the open, and the wake of the
// change can come before the doc is registered.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_change_between_the_stamp_and_the_upsert_of_an_open_is_pushed() {
    let tmp = canon_tmp("open-window");
    std::fs::create_dir_all(tmp.join(".git")).unwrap();
    let open = write_doc(tmp.join("d/a.md"));
    let (fs, release) = stuck_fs();
    // A limit that the held walk cannot reach: a walk that is out wakes a
    // look of its own when it returns.
    let daemon =
        Daemon::with_fs(tmp.join("state.json"), Box::new(Silent), Arc::new(Notify::new()), fs.clone(), Duration::from_secs(30)).await;
    assert_eq!(try_open(&daemon, &open).await, Ok(()));
    let mut app = connect_app(&daemon).await;
    let doc = write_doc(tmp.join("d/b.md"));
    fs.hold(Call::RepoOf, &doc);

    let opening = spawn_open(&daemon, &doc);
    eventually("the held walk", || fs.held(Call::RepoOf) == 1).await;
    let changed = change(&doc);
    drop(release);
    assert_eq!(opening.await.unwrap(), Ok(()));
    let event = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match app.recv().await {
                Some(Msg::FileEvent { path, mtime_ms }) => return (PathBuf::from(path), mtime_ms),
                Some(_) => {}
                None => panic!("the app went away"),
            }
        }
    });
    assert_eq!(event.await.expect("a file_event"), (doc, changed));

    let _ = std::fs::remove_dir_all(&tmp);
}

// A re-open keeps what was seen (`upsert_doc`): a look after it would
// read every doc of the board for nothing.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reopen_in_a_watched_dir_wakes_no_look() {
    let tmp = canon_tmp("reopen-no-look");
    let doc = write_doc(tmp.join("d/a.md"));
    let (fs, _release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    let mut app = connect_app(&daemon).await;
    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    flushed(&mut app, &doc).await;
    let reads = fs.calls(Call::Stamp);

    assert_eq!(try_open(&daemon, &doc).await, Ok(()));
    tokio::time::sleep(3 * crate::watch::BURST).await;
    assert_eq!(fs.calls(Call::Stamp), reads, "a look read the docs");

    let _ = std::fs::remove_dir_all(&tmp);
}
