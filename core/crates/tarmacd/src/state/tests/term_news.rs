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

// S33: the app's notice for a dropped held input, with HOLD_DEADLINE short.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s33_a_dropped_held_input_gives_the_app_one_err_notice() {
    let mut r = rig("held-notice").await;
    let plan = crate::term::SpawnPlan {
        term_id: "T".into(),
        size: (80, 24),
        cwd: Some(r.dir.to_string_lossy().into_owned()),
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "read _".into()]),
        board: "board-0".into(),
        succeeds: None,
    };
    crate::term::spawn_holding(r.daemon.clone(), plan, Duration::from_millis(200)).await.unwrap();
    let handle = r.daemon.term("T").await.expect("T runs");

    let held = crate::term::Input { bytes: [b"y".repeat(1000), b"\r".to_vec()].concat(), hold: true };
    handle.input_tx.send(held).await.unwrap();

    let notices = async {
        let mut notices = Vec::new();
        while let Ok(Some(msg)) = tokio::time::timeout(Duration::from_secs(1), r.app.recv()).await {
            if let Msg::Err { msg } = msg {
                notices.push(msg);
            }
        }
        notices
    };
    assert_eq!(notices.await, vec!["input held for T dropped: the shell did not take keys".to_string()]);
    handle.kill();
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

// D10: the bound is inside the cli's own wait, so the cli hears the daemon.
#[test]
fn the_daemons_bound_is_below_the_clis_wait() {
    assert!(TERM_NEW_APP_WAIT < tarmac_protocol::DAEMON_WAIT);
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
