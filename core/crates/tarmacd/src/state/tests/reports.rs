use super::*;
use crate::term::TermHandle;

// 2611.0009 S36: a caller the walk cannot place, in a terminal with no
// foreground leader, is refused. No live pty has no leader, so the handle is
// one that no process holds.
#[tokio::test]
async fn a_report_with_no_process_to_tie_it_to_is_refused_and_pushes_nothing() {
    let daemon = Daemon::new(tmp_dir("report-no-holder").join("state.json")).await.unwrap();
    let mut app = connect_app(&daemon).await;
    daemon.terms.lock().await.insert("T".into(), TermHandle::detached());

    let answer = daemon.report(None, "T", "done", Some("x".into())).await;

    assert_eq!(answer, Err("no process to tie the report to in T".into()));
    assert!(pushed(&mut app).is_empty());
}
