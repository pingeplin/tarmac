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
