use super::*;

// #259
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_that_does_not_return_costs_only_its_own_doc() {
    let (tmp, daemon, mut app, stuck, _release) = stuck_daemon("stuck-wake").await;
    let doc = write_doc(tmp.join("d/b.md"));
    open_doc(&daemon, None, &doc).await;

    stuck.hold(Call::Stamp, &tmp.join("gone"));
    let changed = change(&doc);
    look_at(&daemon).await;
    assert_eq!(file_events(&mut app), vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// #280: a panic is not a reason to stop the looks of the watch loop.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_that_panics_costs_only_its_own_doc() {
    let (tmp, daemon, mut app, stuck, _release) = stuck_daemon("stamp-panics").await;
    let doc = write_doc(tmp.join("d/b.md"));
    open_doc(&daemon, None, &doc).await;

    stuck.panic_on(&tmp.join("gone/a.md"));
    for _ in 0..2 {
        let changed = change(&doc);
        look_at(&daemon).await;
        assert_eq!(file_events(&mut app), vec![(doc.clone(), changed)]);
    }

    let _ = std::fs::remove_dir_all(&tmp);
}

// A switch looks at the docs of every board, the board it shows among them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_switch_answers_while_a_read_does_not_return() {
    let (tmp, daemon, _app, stuck, _release) = stuck_daemon("stuck-switch").await;
    let other = daemon.boards.lock().await.create();
    let doc = write_doc(tmp.join("d/b.md"));
    open_doc(&daemon, Some(&other), &doc).await;
    daemon.boards.lock().await.set_active(crate::boards::DEFAULT_BOARD_ID);

    stuck.hold(Call::Stamp, &tmp.join("gone"));
    let changed = change(&doc);
    let switch = {
        let daemon = daemon.clone();
        async move {
            daemon
                .look(Boards::doc_paths, |boards, now| {
                    boards.set_active(&other);
                    crate::docs::take_to_tell(&daemon, boards.active_registry_mut(), now)
                })
                .await
        }
    };
    assert_eq!(answers(switch).await, vec![(doc, changed)]);

    let _ = std::fs::remove_dir_all(&tmp);
}

// Each look would otherwise leave one more thread stuck on the same file.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_doc_whose_read_is_out_is_read_again_only_when_it_returned() {
    let (tmp, daemon, mut app, stuck, release) = stuck_daemon("stuck-again").await;
    let doc = write_doc(tmp.join("d/b.md"));
    open_doc(&daemon, None, &doc).await;
    stuck.hold(Call::Stamp, &tmp.join("gone"));
    look_at(&daemon).await;
    assert_eq!(stuck.held(Call::Stamp), 1);

    let changed = change(&doc);
    let before = std::time::Instant::now();
    look_at(&daemon).await;
    assert!(before.elapsed() < LIMIT, "it waited {:?} for a read that is out", before.elapsed());
    assert_eq!(stuck.held(Call::Stamp), 1);
    assert_eq!(file_events(&mut app), vec![(doc, changed)]);

    drop(release);
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while stuck.held(Call::Stamp) < 2 {
        assert!(std::time::Instant::now() < deadline, "the doc is never read again");
        tokio::time::sleep(Duration::from_millis(10)).await;
        look_at(&daemon).await;
    }

    let _ = std::fs::remove_dir_all(&tmp);
}
