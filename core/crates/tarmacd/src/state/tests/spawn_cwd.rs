use super::*;

/// `$HOME` of the test process, canonical.
fn home() -> String {
    std::fs::canonicalize(std::env::var("HOME").unwrap()).unwrap().to_string_lossy().into_owned()
}

async fn rig(tag: &str) -> Rig {
    rig_with(tag, None, LIMIT).await
}

/// A rig whose `is_dir` of its dir does not return.
async fn cwd_out(tag: &str) -> Rig {
    let r = rig(tag).await;
    r.fs.hold(Call::IsDir, &r.dir);
    r
}

/// A rig with a terminal `src` in its dir, whose `pid_cwd` does not return.
async fn inherit_out(tag: &str) -> Rig {
    let mut r = rig(tag).await;
    source_in(&r.daemon, &mut r.app, &r.dir).await;
    r.fs.hold_pid(pid_of(&r.daemon, "src").await);
    r
}

async fn spawn_pwd(daemon: &Arc<Daemon>, term_id: &str, cwd: Option<&Path>, inherit_cwd_from: Option<&str>) -> Duration {
    spawn(daemon, term_id, &["/bin/sh", "-c", "pwd -P"], SpawnOpts { cwd, inherit_cwd_from, ..Default::default() }).await
}

/// A terminal `src` in `dir`, at a `read` once this returns, whose own
/// first `pid_cwd` (2611.0007) has been recorded.
async fn source_in(daemon: &Arc<Daemon>, app: &mut mpsc::Receiver<Msg>, dir: &Path) {
    spawn(daemon, "src", &["/bin/sh", "-c", "echo UP; read _"], SpawnOpts { cwd: Some(dir), ..Default::default() }).await;
    printed(app, "src", Some("UP")).await;
    eventually_async("the record of src's cwd", || async {
        daemon.boards.lock().await.active_registry().term_records["src"].last_cwd.is_some()
    })
    .await;
}

async fn end_source(daemon: &Arc<Daemon>, app: &mut mpsc::Receiver<Msg>) {
    daemon.term("src").await.expect("src runs").kill();
    printed(app, "src", None).await;
}

/// `cwd_out`, after a first spawn `t1` in its dir (S1).
async fn after_a_cwd_out(tag: &str) -> Rig {
    let mut r = cwd_out(tag).await;
    spawn_pwd(&r.daemon, "t1", Some(&r.dir), None).await;
    printed(&mut r.app, "t1", None).await;
    r
}

/// `inherit_out`, after a first spawn `t1` from `src` (S4).
async fn after_an_inherit_out(tag: &str) -> Rig {
    let mut r = inherit_out(tag).await;
    spawn_pwd(&r.daemon, "t1", None, Some("src")).await;
    printed(&mut r.app, "t1", None).await;
    r
}

// 2610.0013 S1
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_whose_cwd_does_not_answer_runs_in_home() {
    let mut r = cwd_out("cwd-out").await;

    let took = spawn_pwd(&r.daemon, "t1", Some(&r.dir), None).await;

    assert!(took < 3 * LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t1", None).await, home());
    assert_eq!(r.fs.held(Call::IsDir), 1);
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S2: and a spawn with no cwd makes no `is_dir` call.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_whose_cwd_is_not_there_runs_in_home_at_once() {
    let mut r = rig("cwd-missing").await;

    let took = spawn_pwd(&r.daemon, "t1", Some(&r.tmp.join("missing")), None).await;
    assert!(took < LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t1", None).await, home());
    assert_eq!(r.fs.calls(Call::IsDir), 1);

    let took = spawn_pwd(&r.daemon, "t2", None, None).await;
    assert!(took < LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t2", None).await, home());
    assert_eq!(r.fs.calls(Call::IsDir), 1);

    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S3
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_runs_in_its_cwd_that_answers() {
    let mut r = rig("cwd-live").await;

    spawn_pwd(&r.daemon, "t1", Some(&r.dir), None).await;

    assert_eq!(printed(&mut r.app, "t1", None).await, r.dir.to_string_lossy());
    assert_eq!(r.fs.calls(Call::IsDir), 1);
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S4
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_whose_source_cwd_does_not_answer_runs_in_home() {
    let mut r = inherit_out("inherit-out").await;

    let took = spawn_pwd(&r.daemon, "t1", None, Some("src")).await;

    assert!(took < 3 * LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t1", None).await, home());
    assert_eq!(r.fs.held(Call::PidCwd), 1);
    end_source(&r.daemon, &mut r.app).await;
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S4b
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_whose_inherited_cwd_does_not_answer_runs_in_home() {
    let mut r = rig("inherit-dir-out").await;
    source_in(&r.daemon, &mut r.app, &r.dir).await;
    r.fs.hold(Call::IsDir, &r.dir);

    let took = spawn_pwd(&r.daemon, "t1", None, Some("src")).await;

    assert!(took < 3 * LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t1", None).await, home());
    // src's own first read (2611.0007), and the inherit's.
    assert_eq!((r.fs.pid_cwd_calls(pid_of(&r.daemon, "src").await), r.fs.held(Call::IsDir)), (2, 1));
    end_source(&r.daemon, &mut r.app).await;
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S5
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_in_a_cwd_that_is_out_runs_in_home_at_once() {
    let mut r = after_a_cwd_out("cwd-out-again").await;

    let took = spawn_pwd(&r.daemon, "t2", Some(&r.dir), None).await;

    assert!(took < LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t2", None).await, home());
    assert_eq!(r.fs.calls(Call::IsDir), 1);
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S5, from the same source terminal.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_from_a_source_whose_cwd_is_out_runs_in_home_at_once() {
    let mut r = after_an_inherit_out("inherit-out-again").await;

    let took = spawn_pwd(&r.daemon, "t2", None, Some("src")).await;

    assert!(took < LIMIT, "the spawn took {took:?}");
    assert_eq!(printed(&mut r.app, "t2", None).await, home());
    // src's own first read (2611.0007), and t1's inherit: none for t2's.
    assert_eq!(r.fs.pid_cwd_calls(pid_of(&r.daemon, "src").await), 2);
    end_source(&r.daemon, &mut r.app).await;
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S6
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_runs_in_its_cwd_again_once_the_call_returned() {
    let mut r = after_a_cwd_out("cwd-back").await;
    r.release();
    eventually("the return of the is_dir", || !r.daemon.gate().is_out_dir(&r.dir)).await;

    spawn_pwd(&r.daemon, "t2", Some(&r.dir), None).await;

    assert_eq!(printed(&mut r.app, "t2", None).await, r.dir.to_string_lossy());
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// #279: a duplicate term_id is refused before its cwd is read.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_duplicate_term_id_is_refused_at_once_while_its_cwd_does_not_answer() {
    let mut r = rig("dup-cwd-out").await;
    source_in(&r.daemon, &mut r.app, &r.dir).await;
    r.fs.hold(Call::IsDir, &r.dir);

    let took = spawn_pwd(&r.daemon, "src", Some(&r.dir), None).await;

    assert!(took < LIMIT, "the refusal took {took:?}");
    let refused = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Msg::Err { msg } = r.app.recv().await.expect("the app is connected") {
                return msg;
            }
        }
    });
    assert_eq!(refused.await.expect("an err frame"), "term_id already in use: src");
    end_source(&r.daemon, &mut r.app).await;
    let _ = std::fs::remove_dir_all(&r.tmp);
}
