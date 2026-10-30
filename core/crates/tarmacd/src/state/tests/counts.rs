use super::*;

/// notify as these tests need it: it watches a directory that is there
/// and refuses one that is not. Real FSEvents streams are left to the
/// integration suites: many that start at once can take one more than the
/// gate's limit to start.
struct ExistingDirs;

impl WakeSource for ExistingDirs {
    fn watch(&mut self, dir: &Path) -> anyhow::Result<()> {
        anyhow::ensure!(dir.is_dir(), "no such directory: {}", dir.display());
        Ok(())
    }

    fn unwatch(&mut self, _: &Path) -> anyhow::Result<()> {
        Ok(())
    }
}

async fn daemon_with_doc_dir(tag: &str) -> (PathBuf, PathBuf, Arc<Daemon>) {
    let tmp = tmp_dir(tag);
    let doc_dir = tmp.join("d");
    std::fs::create_dir_all(&doc_dir).unwrap();
    let daemon = on_source(tmp.join("state.json"), ExistingDirs).await;
    (tmp, doc_dir, daemon)
}

#[tokio::test]
async fn a_dir_is_watched_from_its_first_count_to_its_last() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("count").await;

    daemon.acquire_watch(&doc_dir).await.unwrap();
    daemon.acquire_watch(&doc_dir).await.unwrap();
    assert!(watched(&daemon, &doc_dir).await);

    daemon.release_watch(&doc_dir);
    assert!(watched(&daemon, &doc_dir).await, "one doc is left");
    daemon.release_watch(&doc_dir);
    assert!(!watched(&daemon, &doc_dir).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn closing_the_sole_doc_of_a_dir_unwatches_it() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("close-sole").await;
    let doc = doc_dir.join("a.md");
    open_doc(&daemon, None, &doc).await;
    assert!(watched(&daemon, &doc_dir).await);
    assert!(!watched(&daemon, &tmp).await, "a doc in a subdirectory does not count");

    assert!(daemon.close_doc(&doc).await);
    assert!(!watched(&daemon, &doc_dir).await);
    assert!(!daemon.close_doc(&doc).await, "a second close finds no doc");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn watched_dir_kept_when_sibling_doc_remains() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("s8b").await;
    let doc_a = doc_dir.join("a.md");
    open_doc(&daemon, None, &doc_a).await;
    open_doc(&daemon, None, &doc_dir.join("b.md")).await;

    assert!(daemon.close_doc(&doc_a).await);
    assert!(watched(&daemon, &doc_dir).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn watched_dir_kept_while_another_board_has_a_doc_there() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("close-cross-board").await;
    let (doc_a, doc_b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
    open_doc(&daemon, None, &doc_a).await;
    let other = daemon.boards.lock().await.create();
    open_doc(&daemon, Some(&other), &doc_b).await;

    assert!(daemon.close_doc(&doc_b).await);
    assert!(watched(&daemon, &doc_dir).await, "board-0 still has a doc in the directory");

    daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);
    assert!(daemon.close_doc(&doc_a).await);
    assert!(!watched(&daemon, &doc_dir).await, "no board has a doc in the directory");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn deleting_a_board_unwatches_the_dirs_no_board_is_left_in() {
    let (tmp, shared, daemon) = daemon_with_doc_dir("delete-board").await;
    let own = tmp.join("own");
    std::fs::create_dir_all(&own).unwrap();
    open_doc(&daemon, None, &shared.join("a.md")).await;
    let other = daemon.boards.lock().await.create();
    open_doc(&daemon, Some(&other), &shared.join("b.md")).await;
    open_doc(&daemon, Some(&other), &own.join("c.md")).await;
    open_doc(&daemon, Some(&other), &own.join("d.md")).await;

    assert!(daemon.delete_board(&other).await);
    assert!(!watched(&daemon, &own).await, "no board is left with a doc there");
    assert!(watched(&daemon, &shared).await, "board-0 still has a doc there");
    assert!(!daemon.delete_board(&other).await, "a second delete finds no board");

    assert!(daemon.close_doc(&shared.join("a.md")).await);
    assert!(!watched(&daemon, &shared).await);
    assert!(daemon.doc_counts.0.lock().unwrap().is_empty(), "no count is left at zero");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn reopening_a_doc_counts_it_once() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("reopen").await;
    let doc = doc_dir.join("a.md");
    open_doc(&daemon, None, &doc).await;
    open_doc(&daemon, None, &doc).await;

    assert!(daemon.close_doc(&doc).await);
    assert!(!watched(&daemon, &doc_dir).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn an_open_that_cannot_watch_registers_and_counts_nothing() {
    let (tmp, _, daemon) = daemon_with_doc_dir("open-fails").await;
    let late_dir = tmp.join("late");
    let doc = late_dir.join("a.md");

    assert!(daemon.open_doc(None, &doc, "t", None, None, None).await.is_err(), "the directory does not exist");
    assert!(!daemon.close_doc(&doc).await, "nothing was registered");

    std::fs::create_dir_all(&late_dir).unwrap();
    open_doc(&daemon, None, &doc).await;
    assert!(daemon.close_doc(&doc).await);
    assert!(!watched(&daemon, &late_dir).await, "the failed open left no count");

    let _ = std::fs::remove_dir_all(&tmp);
}

#[tokio::test]
async fn a_restart_counts_every_restored_doc() {
    let tmp = tmp_dir("restart-count");
    let doc_dir = tmp.join("d");
    std::fs::create_dir_all(&doc_dir).unwrap();
    let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
    std::fs::write(tmp.join("state.json"), state_with_docs(&[&a, &b])).unwrap();
    let daemon = on_source(tmp.join("state.json"), ExistingDirs).await;
    assert!(watched(&daemon, &doc_dir).await);

    assert!(daemon.close_doc(&a).await);
    assert!(watched(&daemon, &doc_dir).await, "b.md is left");
    assert!(daemon.close_doc(&b).await);
    assert!(!watched(&daemon, &doc_dir).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

// A directory that is gone at the start cannot be watched, but its doc is
// still registered: it must hold the watch that a later open starts.
#[tokio::test]
async fn a_restored_doc_counts_when_its_dir_could_not_be_watched() {
    let tmp = tmp_dir("restart-missing");
    let doc_dir = tmp.join("d");
    let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
    std::fs::write(tmp.join("state.json"), state_with_docs(&[&a])).unwrap();
    let daemon = on_source(tmp.join("state.json"), ExistingDirs).await;
    assert!(!watched(&daemon, &doc_dir).await);

    std::fs::create_dir_all(&doc_dir).unwrap();
    open_doc(&daemon, None, &b).await;
    assert!(watched(&daemon, &doc_dir).await);
    assert!(daemon.close_doc(&b).await);
    assert!(watched(&daemon, &doc_dir).await, "a.md is left");
    assert!(daemon.close_doc(&a).await);
    assert!(!watched(&daemon, &doc_dir).await);

    let _ = std::fs::remove_dir_all(&tmp);
}

async fn cli_open(daemon: &Arc<Daemon>, doc: &Path) {
    crate::docs::handle_open(daemon, doc.to_str().unwrap(), "cli", None, None).await.unwrap();
}

// #248: an open and a close in one directory, in whatever order the
// scheduler gives. Nothing is delayed; without the count, about one round in
// seven left the new doc registered and its directory unwatched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dir_stays_watched_when_an_open_races_a_close() {
    let (tmp, doc_dir, daemon) = daemon_with_doc_dir("open-races-close").await;
    // An open registers the canonical path (/tmp -> /private/tmp).
    let doc_dir = std::fs::canonicalize(&doc_dir).unwrap();
    let (a, b) = (doc_dir.join("a.md"), doc_dir.join("b.md"));
    std::fs::write(&a, "a").unwrap();
    std::fs::write(&b, "b").unwrap();

    for round in 0..100 {
        cli_open(&daemon, &a).await;
        let opening = tokio::spawn({
            let (daemon, b) = (daemon.clone(), b.clone());
            async move { cli_open(&daemon, &b).await }
        });
        let closing = tokio::spawn({
            let (daemon, a) = (daemon.clone(), a.clone());
            async move { daemon.close_doc(&a).await }
        });
        opening.await.unwrap();
        assert!(closing.await.unwrap());
        assert!(watched(&daemon, &doc_dir).await, "round {round}: b.md is registered");

        assert!(daemon.close_doc(&b).await);
        assert!(!watched(&daemon, &doc_dir).await, "round {round}: no doc is left");
    }

    let _ = std::fs::remove_dir_all(&tmp);
}
