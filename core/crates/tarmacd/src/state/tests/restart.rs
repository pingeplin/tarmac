use super::*;

const RESTORED: u64 = 1_718_000_000_000;

/// A state file with `docs` on board-0, each changed at `RESTORED`.
fn state_changed_at_restored(docs: &[&Path]) -> String {
    let docs: Vec<_> = docs
        .iter()
        .map(|p| serde_json::json!({"path": p, "via": "cli", "read": false, "last_changed_ms": RESTORED}))
        .collect();
    serde_json::json!({"boards": [{"board_id": "board-0", "docs": docs}]}).to_string()
}

/// A restart in a repo, with `gone/a.md` and `gone/c.md`, whose calls are
/// held from the start, and `d/b.md`. Two held docs, so that the stamps
/// of the restart take their two limits: with the walks after them, and
/// not beside them, the restart would take three.
struct Restart {
    tmp: PathBuf,
    gone: PathBuf,
    stuck: PathBuf,
    doc: PathBuf,
    daemon: Arc<Daemon>,
    fs: Arc<StuckFs>,
    calls: Arc<SourceCalls>,
    release: Option<std::sync::mpsc::Sender<()>>,
    took: Duration,
}

async fn restart_with_gone(tag: &str) -> Restart {
    let tmp = canon_tmp(tag);
    std::fs::create_dir_all(tmp.join(".git")).unwrap();
    let gone = tmp.join("gone");
    let (stuck, other) = (write_doc(gone.join("a.md")), write_doc(gone.join("c.md")));
    let doc = write_doc(tmp.join("d/b.md"));
    std::fs::write(tmp.join("state.json"), state_changed_at_restored(&[&stuck, &other, &doc])).unwrap();
    let (fs, release) = stuck_fs();
    fs.hold(Call::Stamp, &gone);
    fs.hold(Call::RepoOf, &gone);
    let (source, calls, _unheld) = held_source(&[]);

    let before = std::time::Instant::now();
    let daemon = answers({
        let (tmp, fs) = (tmp.clone(), fs.clone());
        async move { held(&tmp, source, fs).await }
    })
    .await;
    let took = before.elapsed();
    Restart { tmp, gone, stuck, doc, daemon, fs, calls, release: Some(release), took }
}

// 2610.0012 S17
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_waits_two_limits_at_most_for_the_docs_that_do_not_answer() {
    let r = restart_with_gone("restart-gone").await;
    assert!(r.took < 3 * LIMIT, "it waited {:?}", r.took);
    assert!(registered(&r.daemon, &r.stuck).await && registered(&r.daemon, &r.doc).await);
    let repo = r.tmp.file_name().unwrap().to_string_lossy().into_owned();
    assert_eq!(repo_of(&r.daemon, &r.doc).await.0, Some(repo));
    assert_eq!(repo_of(&r.daemon, &r.stuck).await, (None, None, None));

    let mut app = connect_app(&r.daemon).await;
    look_at(&r.daemon).await;
    assert_eq!(file_events(&mut app), vec![]);
    let changed = change(&r.doc);
    look_at(&r.daemon).await;
    assert_eq!(next_change(&mut app).await, (r.doc.clone(), changed));

    let _ = std::fs::remove_dir_all(&r.tmp);
}

/// Releases the held calls, and waits until none under `gone/` is out.
async fn release_reads(r: &mut Restart) {
    drop(r.release.take());
    eventually("the return of the reads", || !r.daemon.gate().is_out_dir(&r.gone)).await;
}

/// `release_reads`, then a look: every doc has been read since the
/// release.
async fn look_after_the_release(r: &mut Restart) {
    release_reads(r).await;
    let reads = r.fs.calls(Call::Stamp);
    look_at(&r.daemon).await;
    assert!(r.fs.calls(Call::Stamp) >= reads + 3, "the look read every doc");
}

// 2610.0012 S18
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restored_doc_that_was_not_read_is_taken_as_it_is_when_it_answers() {
    let mut r = restart_with_gone("restart-unread").await;
    let mut app = connect_app(&r.daemon).await;

    look_after_the_release(&mut r).await;
    assert_eq!(last_changed(&r.daemon, &r.stuck).await, Some(RESTORED));
    let changed = change(&r.doc);
    look_at(&r.daemon).await;
    assert_eq!(next_change(&mut app).await, (r.doc.clone(), changed), "nothing for the doc that was read");

    let changed = change(&r.stuck);
    look_at(&r.daemon).await;
    assert_eq!(next_change(&mut app).await, (r.stuck.clone(), changed));
    eventually("the watch", || r.calls.of(Change::Watch, &r.gone) == 1).await;
    assert!(watched(&r.daemon, &r.gone).await);
    assert_eq!(r.calls.of(Change::Watch, &r.gone), 1);

    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0012 S19 (D10): a first reading of no file ends `unread` too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restored_doc_whose_file_went_while_it_was_not_read_is_gone() {
    let mut r = restart_with_gone("restart-unread-gone").await;
    let mut app = connect_app(&r.daemon).await;
    std::fs::remove_file(&r.stuck).unwrap();

    look_after_the_release(&mut r).await;
    write_doc(r.stuck.clone());
    let back = crate::boards::epoch_ms(mtime(&r.stuck));
    look_at(&r.daemon).await;
    assert_eq!(next_change(&mut app).await, (r.stuck.clone(), back));

    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0012 S19 (D10): a refresh ends `unread`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refresh_of_a_restored_doc_that_was_not_read_pushes_as_before() {
    let mut r = restart_with_gone("restart-unread-refresh").await;
    let mut app = connect_app(&r.daemon).await;
    release_reads(&mut r).await;

    assert!(crate::docs::stat_and_push(&r.daemon, &r.stuck).await);
    let now = crate::boards::epoch_ms(mtime(&r.stuck));
    assert_eq!(next_change(&mut app).await, (r.stuck.clone(), now));
    let changed = change(&r.stuck);
    look_at(&r.daemon).await;
    assert_eq!(next_change(&mut app).await, (r.stuck.clone(), changed));

    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0012 S19: a file that is missing at the start is read, and gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restored_doc_whose_file_is_missing_is_told_when_it_comes() {
    let tmp = canon_tmp("restart-missing-file");
    let doc = tmp.join("d/a.md");
    std::fs::create_dir_all(tmp.join("d")).unwrap();
    std::fs::write(tmp.join("state.json"), state_changed_at_restored(&[&doc])).unwrap();
    let (fs, _unheld) = stuck_fs();
    let daemon = gated(&tmp, fs).await;
    let mut app = connect_app(&daemon).await;

    write_doc(doc.clone());
    let come = crate::boards::epoch_ms(mtime(&doc));
    look_at(&daemon).await;
    assert_eq!(next_change(&mut app).await, (doc, come));

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S20: the repo comes through the gate, one walk per dir.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_walks_once_for_the_repo_of_each_dir() {
    let tmp = canon_tmp("restart-walks");
    let (one, two) = (tmp.join("one"), tmp.join("two"));
    let docs: Vec<PathBuf> = (0..5)
        .map(|i| write_doc(one.join(format!("{i}.md"))))
        .chain((0..2).map(|i| write_doc(two.join(format!("{i}.md")))))
        .collect();
    let state = state_changed_at_restored(&docs.iter().map(PathBuf::as_path).collect::<Vec<_>>());
    std::fs::write(tmp.join("state.json"), state).unwrap();
    let (fs, _unheld) = stuck_fs();
    fs.answer_repo(&one, "first");
    fs.answer_repo(&two, "second");

    let daemon = gated(&tmp, fs.clone()).await;
    assert_eq!(fs.calls(Call::RepoOf), 2);
    for doc in &docs {
        let (dir, name) = if doc.starts_with(&one) { (&one, "first") } else { (&two, "second") };
        let repo = (Some(name.to_owned()), Some(dir.to_string_lossy().into_owned()), Some(tarmac_protocol::repo_color_index(name)));
        assert_eq!(repo_of(&daemon, doc).await, repo, "{}", doc.display());
    }

    let _ = std::fs::remove_dir_all(&tmp);
}

/// A state file with `docs` on board-1, behind an empty active board-0.
fn state_on_a_background_board(docs: &[&Path]) -> String {
    let docs: Vec<_> = docs
        .iter()
        .map(|p| serde_json::json!({"path": p, "via": "cli", "read": false, "last_changed_ms": RESTORED}))
        .collect();
    serde_json::json!({
        "boards": [{"board_id": "board-0"}, {"board_id": "board-1", "docs": docs}],
        "active": "board-0",
    })
    .to_string()
}

/// Switches to board-1, and what its switch tells.
async fn switch_to_board_1(daemon: &Arc<Daemon>) -> Vec<(PathBuf, u64)> {
    let daemon = daemon.clone();
    answers(async move {
        daemon
            .look(Boards::doc_paths, |boards, now| {
                boards.set_active("board-1");
                crate::docs::take_to_tell(&daemon, boards.active_registry_mut(), now)
            })
            .await
    })
    .await
}

// The startup reading is taken on every board, not on the active one
// only: a change after it is told at the switch. The change comes before
// the look that the startup watch wakes, `BURST` later.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_reads_the_docs_of_a_background_board() {
    let tmp = canon_tmp("restart-background");
    let doc = write_doc(tmp.join("d/a.md"));
    std::fs::write(tmp.join("state.json"), state_on_a_background_board(&[&doc])).unwrap();
    let (fs, _unheld) = stuck_fs();
    let daemon = gated(&tmp, fs).await;

    let changed = change(&doc);
    assert_eq!(switch_to_board_1(&daemon).await, vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// D10: the first reading after the volume answers is the one taken with
// no change, on a background board too, not the first one at its switch.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_background_doc_that_was_not_read_is_read_when_it_answers() {
    let tmp = canon_tmp("restart-background-unread");
    let gone = tmp.join("gone");
    let doc = write_doc(gone.join("a.md"));
    std::fs::write(tmp.join("state.json"), state_on_a_background_board(&[&doc])).unwrap();
    let (fs, release) = stuck_fs();
    fs.hold(Call::Stamp, &gone);
    let daemon = gated(&tmp, fs).await;

    drop(release);
    eventually("the return of the read", || !daemon.gate().is_out_dir(&gone)).await;
    look_at(&daemon).await;
    let changed = change(&doc);
    assert_eq!(switch_to_board_1(&daemon).await, vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// 2610.0012 S20, on a board in the background.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_gives_a_background_board_s_docs_their_repo() {
    let tmp = canon_tmp("restart-background-repo");
    let one = tmp.join("one");
    let doc = write_doc(one.join("a.md"));
    std::fs::write(tmp.join("state.json"), state_on_a_background_board(&[&doc])).unwrap();
    let (fs, _unheld) = stuck_fs();
    fs.answer_repo(&one, "first");
    let daemon = gated(&tmp, fs).await;

    let entry = daemon.boards.lock().await.registry_mut(Some("board-1")).entry(&doc).unwrap();
    let repo = (Some("first".to_owned()), Some(one.to_string_lossy().into_owned()), Some(tarmac_protocol::repo_color_index("first")));
    assert_eq!((entry.repo, entry.repo_root, entry.repo_color), repo);

    let _ = std::fs::remove_dir_all(&tmp);
}
