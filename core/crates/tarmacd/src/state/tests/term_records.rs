use super::*;
use tarmac_protocol::TermRecord;

const TICK: Duration = crate::term::PROC_POLL_INTERVAL;
/// Well above `SHUTDOWN_CWD_BUDGET`: only the budget can end a held read.
const LONG_LIMIT: Duration = Duration::from_secs(30);

fn two_boards() -> serde_json::Value {
    serde_json::json!({"boards": [{"board_id": "board-0"}, {"board_id": "board-1"}], "active": "board-0"})
}

/// The step of a `SpawnTerm` of a shell idle at `read`.
async fn spawn_idle(daemon: &Arc<Daemon>, term_id: &str, opts: SpawnOpts<'_>) {
    spawn(daemon, term_id, &["/bin/sh", "-c", "read _"], opts).await;
}

fn in_dir(dir: &Path) -> SpawnOpts<'_> {
    SpawnOpts { cwd: Some(dir), ..Default::default() }
}

async fn record(daemon: &Daemon, board: &str, term_id: &str) -> Option<TermRecord> {
    daemon.boards.lock().await.known_registry(board)?.term_records.get(term_id).cloned()
}

async fn on_any_board(daemon: &Daemon, term_id: &str) -> bool {
    daemon.boards.lock().await.iter().any(|b| b.registry.term_records.contains_key(term_id))
}

fn cwd(path: &str) -> Option<TermRecord> {
    Some(TermRecord { last_cwd: Some(path.into()) })
}

async fn until_recorded(daemon: &Daemon, term_id: &str, dir: &Path) {
    let want = cwd(&dir.to_string_lossy());
    eventually_async(&format!("the record of {term_id}"), || async { record(daemon, "board-0", term_id).await == want }).await;
}

// 2611.0007 S24
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_idle_terminal_reads_its_cwd_no_more() {
    let r = rig_with("idle-cwd", None, LIMIT).await;
    spawn_idle(&r.daemon, "T", in_dir(&r.dir)).await;
    until_recorded(&r.daemon, "T", &r.dir).await;
    let before = r.fs.calls(Call::PidCwd);

    tokio::time::sleep(Duration::from_secs(3)).await;

    assert_eq!(r.fs.calls(Call::PidCwd), before);
    r.end().await;
}

// 2611.0007 S25
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_moved_record_keeps_its_cwd_through_a_read_with_no_answer() {
    let seeded = serde_json::json!({"boards": [{"board_id": "board-0", "term_records": {"T": {"last_cwd": "/b"}}}]});
    let r = rig_with("moved-cwd", Some(seeded), LIMIT).await;
    r.fs.answer_cwd(None, None);

    spawn_idle(&r.daemon, "T2", SpawnOpts { succeeds: Some("T"), ..in_dir(&r.dir) }).await;
    eventually("the return of T2's first pid_cwd", || r.fs.cwds_returned() >= 1).await;
    tokio::time::sleep(TICK).await;

    assert_eq!(record(&r.daemon, "board-0", "T2").await, cwd("/b"));
    assert_eq!(record(&r.daemon, "board-0", "T").await, None);
    r.end().await;
}

// 2611.0007 S17
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_held_cwd_read_ends_the_shutdown_save_at_its_budget() {
    let r = rig_with("shutdown-save", None, LONG_LIMIT).await;
    for term_id in ["T1", "T2", "T3"] {
        spawn_idle(&r.daemon, term_id, in_dir(&r.dir)).await;
        until_recorded(&r.daemon, term_id, &r.dir).await;
    }
    r.fs.answer_cwd(Some(pid_of(&r.daemon, "T1").await), Some("/fresh/1"));
    r.fs.answer_cwd(None, Some("/fresh/held"));
    r.fs.hold_pid(pid_of(&r.daemon, "T2").await);
    r.fs.hold_pid(pid_of(&r.daemon, "T3").await);

    let started = std::time::Instant::now();
    let daemon = r.daemon.clone();
    within(tokio::spawn(async move { daemon.final_save().await })).await;

    // Two held reads share one deadline: the save waits it out once.
    let took = started.elapsed();
    let budget = crate::persist::SHUTDOWN_CWD_BUDGET;
    assert!(took >= budget && took < budget + Duration::from_millis(300), "the save took {took:?}");
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(r.tmp.join("state.json")).unwrap()).unwrap();
    let records = &saved["boards"][0]["term_records"];
    assert_eq!(records["T1"]["last_cwd"], "/fresh/1");
    assert_eq!(records["T2"]["last_cwd"], serde_json::json!(r.dir));
    assert_eq!(records["T3"]["last_cwd"], serde_json::json!(r.dir));
    r.end().await;
}

/// A rig on two boards whose `pid_cwd` answers `/late` once the test
/// releases it, with a shell `T` on board-1 whose first read has started
/// and is still held.
async fn late_read(tag: &str) -> Rig {
    let r = rig_with(tag, Some(two_boards()), LONG_LIMIT).await;
    r.fs.hold(Call::PidCwd, Path::new(""));
    r.fs.answer_cwd(None, Some("/late"));
    spawn_idle(&r.daemon, "T", SpawnOpts { board: Some("board-1"), ..in_dir(&r.dir) }).await;
    eventually("T's first pid_cwd", || r.fs.calls(Call::PidCwd) >= 1).await;
    assert_eq!(r.fs.cwds_returned(), 0, "the first read is still held");
    r
}

/// Lets the held read return, and gives its answer a tick to land.
async fn returned(r: &mut Rig) {
    r.release();
    eventually("the return of the held pid_cwd", || r.fs.cwds_returned() >= 1).await;
    tokio::time::sleep(TICK).await;
}

// 2611.0007 S23 (a)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_late_read_after_a_close_stores_nothing() {
    let mut r = late_read("late-close").await;
    r.daemon.close_term("T").await;
    printed(&mut r.app, "T", None).await;

    returned(&mut r).await;

    assert!(!on_any_board(&r.daemon, "T").await);
    r.end().await;
}

// 2611.0007 S23 (b)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_late_read_after_a_board_delete_stores_nothing() {
    let mut r = late_read("late-delete").await;
    assert!(r.daemon.delete_board("board-1").await);

    returned(&mut r).await;

    assert!(!on_any_board(&r.daemon, "T").await);
    r.end().await;
}

// 2611.0007: the first read of a terminal on a background board, held until
// its spawn has returned, lands in that board's table and no other.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_first_read_lands_in_the_terms_own_board() {
    let mut r = late_read("first-read-board").await;

    returned(&mut r).await;

    assert_eq!(record(&r.daemon, "board-1", "T").await, cwd("/late"));
    assert_eq!(record(&r.daemon, "board-0", "T").await, None);
    r.end().await;
}
