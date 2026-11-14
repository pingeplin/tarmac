use super::*;
use tarmac_protocol::TermRecord;

const TICK: Duration = crate::term::PROC_POLL_INTERVAL;
/// Well above `SHUTDOWN_CWD_BUDGET`: only the budget can end a held read.
const LONG_LIMIT: Duration = Duration::from_secs(30);

/// A daemon on `StuckFs` that loads `state`, its app, and a dir of its own.
/// The test keeps `release` to its end.
struct Rig {
    tmp: PathBuf,
    dir: PathBuf,
    daemon: Arc<Daemon>,
    app: mpsc::Receiver<Msg>,
    fs: Arc<StuckFs>,
    release: std::sync::mpsc::Sender<()>,
}

impl Rig {
    async fn end(self) {
        drop(self.release);
        let terms: Vec<_> = self.daemon.terms.lock().await.values().cloned().collect();
        for term in terms {
            term.kill();
        }
        let _ = std::fs::remove_dir_all(&self.tmp);
    }
}

async fn rig(tag: &str, state: Option<serde_json::Value>, limit: Duration) -> Rig {
    let tmp = canon_tmp(tag);
    let dir = tmp.join("d");
    std::fs::create_dir_all(&dir).unwrap();
    if let Some(state) = state {
        std::fs::write(tmp.join("state.json"), state.to_string()).unwrap();
    }
    let (fs, release) = stuck_fs();
    let daemon = Daemon::with_fs(tmp.join("state.json"), Box::new(Silent), Arc::new(Wake::default()), fs.clone(), limit).await;
    let app = connect_app(&daemon).await;
    Rig { tmp, dir, daemon, app, fs, release }
}

fn two_boards() -> serde_json::Value {
    serde_json::json!({"boards": [{"board_id": "board-0"}, {"board_id": "board-1"}], "active": "board-0"})
}

/// The step of a `SpawnTerm` of a shell idle at `read`.
async fn spawn_idle(daemon: &Arc<Daemon>, term_id: &str, board: Option<&str>, cwd: Option<&Path>, succeeds: Option<&str>) {
    let (daemon, term_id) = (daemon.clone(), term_id.to_owned());
    let cmd = ["/bin/sh", "-c", "read _"].iter().map(|a| a.to_string()).collect();
    let (board, cwd) = (board.map(str::to_owned), cwd.map(|c| c.to_string_lossy().into_owned()));
    let succeeds = succeeds.map(str::to_owned);
    within(tokio::spawn(async move {
        crate::conn::spawn_requested(&daemon, term_id, (80, 24), cwd, Some(cmd), board, None, succeeds).await
    }))
    .await;
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
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while record(daemon, "board-0", term_id).await != want {
        assert!(std::time::Instant::now() < deadline, "{term_id} was never recorded in {}", dir.display());
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn exited(app: &mut mpsc::Receiver<Msg>, term_id: &str) {
    let exit = async {
        loop {
            if let Msg::Exit { term_id: t, .. } = app.recv().await.expect("the app is connected")
                && t == term_id
            {
                return;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), exit).await.expect("the exit");
}

async fn pid_of(daemon: &Daemon, term_id: &str) -> libc::pid_t {
    daemon.term(term_id).await.expect("the term runs").foreground_pid().expect("a foreground pid")
}

// 2611.0007 S24
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_idle_terminal_reads_its_cwd_no_more() {
    let r = rig("idle-cwd", None, LIMIT).await;
    spawn_idle(&r.daemon, "T", None, Some(&r.dir), None).await;
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
    let r = rig("moved-cwd", Some(seeded), LIMIT).await;
    r.fs.answer_cwd(None, None);

    spawn_idle(&r.daemon, "T2", None, Some(&r.dir), Some("T")).await;
    eventually("the return of T2's first pid_cwd", || r.fs.cwds_returned() >= 1).await;
    tokio::time::sleep(TICK).await;

    assert_eq!(record(&r.daemon, "board-0", "T2").await, cwd("/b"));
    assert_eq!(record(&r.daemon, "board-0", "T").await, None);
    r.end().await;
}

// 2611.0007 S17
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_held_cwd_read_ends_the_shutdown_save_at_its_budget() {
    let r = rig("shutdown-save", None, LONG_LIMIT).await;
    for term_id in ["T1", "T2", "T3"] {
        spawn_idle(&r.daemon, term_id, None, Some(&r.dir), None).await;
        until_recorded(&r.daemon, term_id, &r.dir).await;
    }
    r.fs.answer_cwd(Some(pid_of(&r.daemon, "T1").await), Some("/fresh/1"));
    r.fs.answer_cwd(Some(pid_of(&r.daemon, "T2").await), Some("/fresh/2"));
    r.fs.hold_pid(pid_of(&r.daemon, "T3").await);

    let started = std::time::Instant::now();
    let daemon = r.daemon.clone();
    within(tokio::spawn(async move { crate::persist::final_save(&daemon).await })).await;

    let took = started.elapsed();
    assert!(took < crate::persist::SHUTDOWN_CWD_BUDGET + Duration::from_millis(300), "the save took {took:?}");
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(r.tmp.join("state.json")).unwrap()).unwrap();
    let records = &saved["boards"][0]["term_records"];
    assert_eq!(records["T1"]["last_cwd"], "/fresh/1");
    assert_eq!(records["T2"]["last_cwd"], "/fresh/2");
    assert_eq!(records["T3"]["last_cwd"], serde_json::json!(r.dir));
    r.end().await;
}

/// A rig whose `pid_cwd` answers `/late` once the test releases it, with a
/// shell `T` on board-1 whose first read has started.
async fn late_read(tag: &str) -> Rig {
    let r = rig(tag, Some(two_boards()), LONG_LIMIT).await;
    r.fs.hold(Call::PidCwd, Path::new(""));
    r.fs.answer_cwd(None, Some("/late"));
    spawn_idle(&r.daemon, "T", Some("board-1"), Some(&r.dir), None).await;
    eventually("T's first pid_cwd", || r.fs.calls(Call::PidCwd) >= 1).await;
    r
}

/// Lets the held read return, and gives its answer a tick to land.
async fn returned(r: Rig) -> Rig {
    let Rig { tmp, dir, daemon, app, fs, release } = r;
    drop(release);
    eventually("the return of the held pid_cwd", || fs.cwds_returned() >= 1).await;
    tokio::time::sleep(TICK).await;
    Rig { tmp, dir, daemon, app, fs, release: std::sync::mpsc::channel().0 }
}

// 2611.0007 S23 (a)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_late_read_after_a_close_stores_nothing() {
    let mut r = late_read("late-close").await;
    r.daemon.close_term("T").await;
    exited(&mut r.app, "T").await;

    let r = returned(r).await;

    assert!(!on_any_board(&r.daemon, "T").await);
    r.end().await;
}

// 2611.0007 S23 (b)
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_late_read_after_a_board_delete_stores_nothing() {
    let r = late_read("late-delete").await;
    assert!(r.daemon.delete_board("board-1").await);

    let r = returned(r).await;

    assert!(!on_any_board(&r.daemon, "T").await);
    r.end().await;
}
