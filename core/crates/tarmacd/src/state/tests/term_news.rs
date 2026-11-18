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
