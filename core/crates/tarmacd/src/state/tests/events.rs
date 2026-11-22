//! Spec 2611.0012: the fan-out, the exit ring and the terms list, at the
//! daemon's state.

use super::*;
use crate::term::TermHandle;

/// The next frame of `rx` that `pred` matches, within 5 s.
async fn next_matching(rx: &mut tokio::sync::broadcast::Receiver<Msg>, pred: impl Fn(&Msg) -> bool) -> Msg {
    let found = async {
        loop {
            let msg = rx.recv().await.expect("the fan-out is open");
            if pred(&msg) {
                return msg;
            }
        }
    };
    tokio::time::timeout(Duration::from_secs(5), found).await.expect("a frame")
}

fn is_file_event(msg: &Msg, path: &Path) -> bool {
    matches!(msg, Msg::FileEvent { path: p, .. } if Path::new(p) == path)
}

fn exits(daemon: &Daemon, term_id: &str) -> Option<Option<i64>> {
    daemon.exits.lock().unwrap().lookup(term_id)
}

// S18
#[tokio::test]
async fn an_ended_term_is_in_the_ring_and_out_of_terms() {
    let daemon = on_source(tmp_dir("ring").join("state.json"), Silent).await;
    daemon.terms.lock().await.insert("T".into(), TermHandle::detached());

    daemon.term_ended("T", Some(3)).await;

    assert_eq!(exits(&daemon, "T"), Some(Some(3)));
    assert!(daemon.term("T").await.is_none());
}

// S19, at the state: the snapshot of a reused id.
#[tokio::test]
async fn a_live_term_wins_over_its_exit_in_the_ring() {
    let daemon = on_source(tmp_dir("ring-live").join("state.json"), Silent).await;
    daemon.exits.lock().unwrap().record("T", Some(3));
    let exited = daemon.subscribe(Some(vec!["exit".into()]), Some("T".into())).await.ok().unwrap();
    daemon.terms.lock().await.insert("T".into(), TermHandle::detached());

    let live = daemon.subscribe(Some(vec!["exit".into()]), Some("T".into())).await.ok().unwrap();

    assert_eq!(exited.snapshot, vec![Msg::Exit { term_id: "T".into(), code: Some(3), board_id: None }]);
    assert_eq!(live.snapshot, vec![]);
}

// S22
#[tokio::test]
async fn a_file_event_reaches_a_subscriber_and_the_doc_is_still_held_with_no_app() {
    let tmp = tmp_dir("tap-held");
    let doc = write_doc(tmp.join("a.md"));
    let daemon = on_source(tmp.join("state.json"), Silent).await;
    open_doc(&daemon, None, &doc).await;
    let mut rx = daemon.events.subscribe();
    let board = daemon.boards.lock().await.active_id().to_string();

    crate::docs::push_file_event(&daemon, &board, &doc, 5).await;

    let told = next_matching(&mut rx, |m| matches!(m, Msg::FileEvent { mtime_ms: 5, .. })).await;
    assert_eq!(told, crate::docs::file_event(&doc, 5));
    assert!(daemon.boards.lock().await.active_registry().docs[&doc].untold);
}

// A `doc_refresh` and a `data_file` tell the app of a file too: each is
// published, the same file again included (D5).
#[tokio::test]
async fn a_refresh_and_a_data_file_reach_a_subscriber() {
    let tmp = canon_tmp("tap-refresh");
    let doc = write_doc(tmp.join("dash.html"));
    let data = write_doc(tmp.join("stats.json"));
    let daemon = on_source(tmp.join("state.json"), Silent).await;
    let _app = connect_app(&daemon).await;
    open_doc(&daemon, None, &doc).await;
    let board = daemon.boards.lock().await.active_id().to_string();
    let mut rx = daemon.events.subscribe();

    assert!(crate::docs::stat_and_push(&daemon, &doc).await);
    next_matching(&mut rx, |m| is_file_event(m, &doc)).await;
    assert!(crate::docs::record_data(&daemon, &board, &doc, Some(data.clone())).await);
    next_matching(&mut rx, |m| is_file_event(m, &data)).await;
}

// S22
#[tokio::test]
async fn push_with_an_app_and_no_subscriber_reaches_the_app() {
    let daemon = on_source(tmp_dir("tap-app").join("state.json"), Silent).await;
    let mut app = connect_app(&daemon).await;
    let output = Msg::Output { term_id: "t1".into(), bytes: b"x".to_vec() };

    assert!(daemon.push(output.clone()).await);
    assert_eq!(pushed(&mut app), vec![output]);
}

// S23
#[tokio::test]
async fn subscribers_and_the_terms_list_make_no_watch() {
    let tmp = tmp_dir("no-watch");
    let doc = write_doc(tmp.join("d/a.md"));
    let (source, calls, _release) = held_source(&[]);
    let daemon = Daemon::with_source(tmp.join("state.json"), source, Arc::new(Wake::default())).await;
    open_doc(&daemon, None, &doc).await;
    assert!(watched(&daemon, doc.parent().unwrap()).await);
    daemon.terms.lock().await.insert("T".into(), TermHandle::detached());
    let shapes: [(Option<&[&str]>, Option<&str>); 5] = [
        (None, None),
        (None, Some("T")),
        (Some(&["changed"]), None),
        (Some(&["exit", "report"]), Some("T")),
        (Some(&["later"]), None),
    ];

    let mut subscribers = Vec::new();
    for (kinds, term_id) in shapes {
        let kinds = kinds.map(|k| k.iter().map(ToString::to_string).collect());
        subscribers.push(daemon.subscribe(kinds, term_id.map(str::to_string)).await);
    }
    daemon.terms_list().await;
    drop(subscribers);
    tokio::time::sleep(Duration::from_millis(300)).await;

    assert_eq!((calls.count(Change::Watch), calls.count(Change::Unwatch)), (1, 0));
}

// S24
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_cwd_reads_of_the_terms_list_run_at_the_same_time() {
    let r = rig("terms-stuck").await;
    for term_id in ["t1", "t2", "t3", "t4"] {
        spawn_idle(&r.daemon, term_id, SpawnOpts::default()).await;
    }
    for term_id in ["t1", "t2", "t3", "t4"] {
        eventually_async("each term's first cwd read", || async {
            r.daemon.boards.lock().await.active_registry().term_records[term_id].last_cwd.is_some()
        })
        .await;
    }
    r.fs.hold(Call::PidCwd, Path::new(""));

    let started = std::time::Instant::now();
    let rows = answers({
        let daemon = r.daemon.clone();
        async move { daemon.terms_list().await }
    })
    .await;
    let took = started.elapsed();

    assert!(took < 2 * LIMIT, "the list took {took:?}");
    assert_eq!(rows.iter().map(|row| row.term_id.as_str()).collect::<Vec<_>>(), ["t1", "t2", "t3", "t4"]);
    assert!(rows.iter().all(|row| row.cwd.is_none() && row.proc.is_some()), "{rows:?}");
    r.end().await;
}
