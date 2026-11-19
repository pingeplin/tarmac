use super::*;

/// The `req_id` of the `term_new` the app gets.
async fn forwarded(app: &mut mpsc::Receiver<Msg>) -> u64 {
    let wait = async {
        loop {
            if let Some(Msg::TermNew { req_id: Some(req_id), .. }) = app.recv().await {
                return req_id;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), wait).await.expect("the app gets the term_new")
}

// S28: the daemon's own bound, set short; the spec's 4 s is TERM_NEW_APP_WAIT.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s28_an_app_that_never_answers_is_no_answer_at_the_bound_and_a_late_answer_is_dropped() {
    let mut r = rig("term-new-wait").await;
    let daemon = r.daemon.clone();
    let cwd = r.dir.to_string_lossy().into_owned();
    let asked = tokio::spawn(async move { daemon.term_new("echo hi".into(), cwd, None, Duration::from_millis(200)).await });
    let req_id = forwarded(&mut r.app).await;

    let answer = within(asked).await;

    assert_eq!(answer, Err("the app did not answer".to_string()));
    assert!(r.daemon.term_news.take(req_id).is_none(), "the request is gone at the bound");
    r.daemon.term_new_answered(req_id, Ok("t9".into())).await;
    assert!(r.daemon.terms_list().await.is_empty(), "the daemon goes on serving");
    r.end().await;
}

/// A canonical shell `T`, whose held inputs wait at most `hold`, and its handle.
async fn canonical_term(r: &Rig, hold: Duration) -> Arc<crate::term::TermHandle> {
    let plan = crate::term::SpawnPlan {
        term_id: "T".into(),
        size: (80, 24),
        cwd: Some(r.dir.to_string_lossy().into_owned()),
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "read _".into()]),
        board: "board-0".into(),
        succeeds: None,
    };
    crate::term::spawn_holding(r.daemon.clone(), plan, hold).await.unwrap();
    r.daemon.term("T").await.expect("T runs")
}

fn held(n: usize) -> crate::term::Input {
    crate::term::Input { bytes: [b"y".repeat(n), b"\r".to_vec()].concat(), hold: true }
}

/// The `err` notices the app gets until none comes for `quiet`.
async fn notices(app: &mut mpsc::Receiver<Msg>, quiet: Duration) -> Vec<String> {
    let mut notices = Vec::new();
    while let Ok(Some(msg)) = tokio::time::timeout(quiet, app.recv()).await {
        if let Msg::Err { msg } = msg {
            notices.push(msg);
        }
    }
    notices
}

// S33: the app's notice for a dropped held input, with HOLD_DEADLINE short.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s33_a_dropped_held_input_gives_the_app_one_err_notice() {
    let mut r = rig("held-notice").await;
    let handle = canonical_term(&r, Duration::from_millis(200)).await;

    handle.input_tx.send(held(1000)).await.unwrap();

    assert_eq!(notices(&mut r.app, Duration::from_secs(1)).await, vec!["input held for T dropped: the shell did not take keys".to_string()]);
    handle.kill();
    r.end().await;
}

// D11 End: a held input whose terminal ends before its deadline is neither
// written nor dropped with a notice.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_held_input_whose_terminal_ends_gives_no_notice() {
    let mut r = rig("held-end").await;
    let handle = canonical_term(&r, Duration::from_secs(3)).await;
    handle.input_tx.send(held(1000)).await.unwrap();

    handle.kill();
    drop(handle);

    assert_eq!(notices(&mut r.app, Duration::from_secs(5)).await, Vec::<String>::new());
    r.end().await;
}

// D10: one deadline for the whole request, the folder's read on the gate
// included. The gate's own limit is longer than the bound here.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_folder_read_that_holds_ends_at_the_requests_bound_as_not_a_directory() {
    let r = rig_with("term-new-folder", None, Duration::from_secs(3)).await;
    r.fs.hold(crate::fixtures::Call::IsDir, &r.dir);
    let cwd = r.dir.to_string_lossy().into_owned();
    let started = std::time::Instant::now();

    let answer = r.daemon.term_new("echo hi".into(), cwd.clone(), None, Duration::from_millis(200)).await;

    assert_eq!(answer, Err(format!("not a directory: {cwd}")));
    assert!(started.elapsed() < Duration::from_secs(1), "answered after {:?}", started.elapsed());
    r.end().await;
}

#[test]
fn an_app_gone_ends_only_the_requests_of_its_own_connection() {
    let news = TermNews::default();
    let (first, mut first_rx) = news.wait(1);
    let (second, mut second_rx) = news.wait(2);

    news.app_gone(1);

    assert_eq!(first_rx.try_recv(), Ok(Err("the app went away".to_string())));
    assert!(news.take(first).is_none());
    assert!(second_rx.try_recv().is_err(), "the other connection's request still waits");
    assert!(news.take(second).is_some());
}

// D10: the folder's read and the app's answer share the one bound. A read
// that takes most of it leaves the app only the rest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_folder_read_leaves_the_app_only_the_rest_of_the_bound() {
    let mut r = rig_with("term-new-shared", None, Duration::from_secs(3)).await;
    r.fs.slow(crate::fixtures::Call::IsDir, &r.dir, Duration::from_millis(600));
    let daemon = r.daemon.clone();
    let cwd = r.dir.to_string_lossy().into_owned();
    let started = std::time::Instant::now();
    let asked = tokio::spawn(async move { daemon.term_new("echo hi".into(), cwd, None, Duration::from_millis(800)).await });
    forwarded(&mut r.app).await;

    let answer = within(asked).await;

    assert_eq!(answer, Err("the app did not answer".to_string()));
    let took = started.elapsed();
    assert!(took >= Duration::from_millis(600) && took < Duration::from_millis(1100), "answered after {took:?}");
    r.end().await;
}
