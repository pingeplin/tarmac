use super::*;

/// `$HOME` of the test process, canonical.
fn home() -> String {
    std::fs::canonicalize(std::env::var("HOME").unwrap()).unwrap().to_string_lossy().into_owned()
}

/// A daemon on `StuckFs`, its app, and a dir in a temp dir of its own,
/// which is not under `$HOME`. The test keeps `release` to its end.
struct Rig {
    tmp: PathBuf,
    dir: PathBuf,
    daemon: Arc<Daemon>,
    app: mpsc::Receiver<Msg>,
    fs: Arc<StuckFs>,
    release: std::sync::mpsc::Sender<()>,
}

async fn rig(tag: &str) -> Rig {
    let tmp = canon_tmp(tag);
    let dir = tmp.join("d");
    std::fs::create_dir_all(&dir).unwrap();
    let (fs, release) = stuck_fs();
    let daemon = gated(&tmp, fs.clone()).await;
    let app = connect_app(&daemon).await;
    Rig { tmp, dir, daemon, app, fs, release }
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
    r.fs.hold(Call::PidCwd, Path::new(""));
    r
}

/// The step of a `SpawnTerm` of `argv`, on a task of its own, and how long
/// it took to return.
async fn spawn(
    daemon: &Arc<Daemon>,
    term_id: &str,
    argv: &[&str],
    cwd: Option<&Path>,
    inherit_cwd_from: Option<&str>,
) -> Duration {
    let (daemon, term_id) = (daemon.clone(), term_id.to_owned());
    let cmd = argv.iter().map(|a| a.to_string()).collect();
    let cwd = cwd.map(|c| c.to_string_lossy().into_owned());
    let inherit_cwd_from = inherit_cwd_from.map(str::to_owned);
    let started = std::time::Instant::now();
    within(tokio::spawn(async move {
        crate::conn::spawn_requested(&daemon, term_id, (80, 24), cwd, Some(cmd), None, inherit_cwd_from).await
    }))
    .await;
    started.elapsed()
}

async fn spawn_pwd(daemon: &Arc<Daemon>, term_id: &str, cwd: Option<&Path>, inherit_cwd_from: Option<&str>) -> Duration {
    spawn(daemon, term_id, &["/bin/sh", "-c", "pwd -P"], cwd, inherit_cwd_from).await
}

/// What `term_id` printed until `until` is in it, or to its exit when
/// `until` is `None`. An `err` frame fails the test.
async fn printed(app: &mut mpsc::Receiver<Msg>, term_id: &str, until: Option<&str>) -> String {
    let mut out = Vec::new();
    let frames = async {
        loop {
            match app.recv().await.expect("the app is connected") {
                Msg::Output { term_id: t, bytes } if t == term_id => {
                    out.extend(bytes);
                    if until.is_some_and(|u| String::from_utf8_lossy(&out).contains(u)) {
                        return;
                    }
                }
                Msg::Exit { term_id: t, .. } if t == term_id => return,
                Msg::Err { msg } => panic!("an err frame: {msg}"),
                _ => {}
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), frames).await.expect("the term's frames");
    String::from_utf8_lossy(&out).trim().to_owned()
}

/// A terminal `src` in `dir`, at a `read` once this returns.
async fn source_in(daemon: &Arc<Daemon>, app: &mut mpsc::Receiver<Msg>, dir: &Path) {
    spawn(daemon, "src", &["/bin/sh", "-c", "echo UP; read _"], Some(dir), None).await;
    printed(app, "src", Some("UP")).await;
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
    assert_eq!((r.fs.calls(Call::PidCwd), r.fs.held(Call::IsDir)), (1, 1));
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
    assert_eq!(r.fs.calls(Call::PidCwd), 1);
    end_source(&r.daemon, &mut r.app).await;
    let _ = std::fs::remove_dir_all(&r.tmp);
}

// 2610.0013 S6
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_spawn_runs_in_its_cwd_again_once_the_call_returned() {
    let mut r = after_a_cwd_out("cwd-back").await;
    drop(r.release);
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
