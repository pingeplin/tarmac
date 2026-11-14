use super::*;
use crate::proc::{Facts, Pid};
use crate::term::TermHandle;

/// A rig with a shell `T` idle at `read _` and the resume command `echo HI`.
/// No peer: the walk falls back to the leader, the PTY child, which the set
/// ties to its start time. The handle is kept: `term_ended` takes `T` out of
/// `terms`, where `Rig::end` would no longer find it to kill it.
async fn resumed(tag: &str) -> (Rig, Arc<TermHandle>) {
    let r = rig_with(tag, None, LIMIT).await;
    spawn(&r.daemon, "T", &["/bin/sh", "-c", "read _"], SpawnOpts { cwd: Some(&r.dir), ..Default::default() }).await;
    let handle = r.daemon.term("T").await.expect("T runs");
    assert_eq!(r.daemon.set_resume(None, "T", Some("echo HI".into())).await, Ok(()));
    assert_eq!(resume_of(&r.daemon).await.as_deref(), Some("echo HI"));
    (r, handle)
}

async fn resume_of(daemon: &Daemon) -> Option<String> {
    let boards = daemon.boards.lock().await;
    boards.known_registry("board-0")?.term_records.get("T")?.resume.as_ref().map(|r| r.cmd.clone())
}

async fn has_entry(daemon: &Daemon) -> bool {
    daemon.boards.lock().await.known_registry("board-0").is_some_and(|reg| reg.term_records.contains_key("T"))
}

fn gone(_: Pid) -> Facts {
    Facts::Gone
}

/// The holder's pid, and a process table where it is live with `shift`
/// added to its real start time.
async fn holder_live_with(daemon: &Daemon, shift: u64) -> impl Fn(Pid) -> Facts + use<> {
    let pid = pid_of(daemon, "T").await;
    let Facts::Live { started: real, .. } = proc::proc_facts(pid) else { panic!("the shell's facts are unread") };
    let started = real + shift;
    move |p| if p == pid { Facts::Live { ppid: 1, started } } else { Facts::Gone }
}

async fn end(r: Rig, handle: Arc<TermHandle>) {
    handle.kill();
    r.end().await;
}

// S16
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_under_shutdown_a_gone_holder_and_a_failed_exit_keep_the_command() {
    let (r, handle) = resumed("resume-freeze").await;

    r.daemon.final_save().await;
    r.daemon.check_resume("T", &handle, gone).await;
    r.daemon.term_ended("T", Some(3)).await;

    assert_eq!(resume_of(&r.daemon).await.as_deref(), Some("echo HI"));
    end(r, handle).await;
}

// S16, the first control
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_with_no_shutdown_a_gone_holder_drops_the_command() {
    let (r, handle) = resumed("resume-gone").await;

    r.daemon.check_resume("T", &handle, gone).await;

    assert_eq!(resume_of(&r.daemon).await, None);
    assert!(has_entry(&r.daemon).await);
    end(r, handle).await;
}

// S16, the second control
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_with_no_shutdown_a_live_holder_keeps_it_and_a_failed_exit_drops_it() {
    let (r, handle) = resumed("resume-live").await;
    let live = holder_live_with(&r.daemon, 0).await;

    r.daemon.check_resume("T", &handle, live).await;
    assert_eq!(resume_of(&r.daemon).await.as_deref(), Some("echo HI"));
    r.daemon.term_ended("T", Some(3)).await;

    assert_eq!(resume_of(&r.daemon).await, None);
    assert!(has_entry(&r.daemon).await);
    end(r, handle).await;
}

// S16: a reused pid
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_a_holder_pid_with_another_start_time_drops_the_command() {
    let (r, handle) = resumed("resume-reused").await;
    let reused = holder_live_with(&r.daemon, 1).await;

    r.daemon.check_resume("T", &handle, reused).await;

    assert_eq!(resume_of(&r.daemon).await, None);
    end(r, handle).await;
}

// S16: an unread holder
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_an_unread_holder_keeps_the_command() {
    let (r, handle) = resumed("resume-unread").await;

    r.daemon.check_resume("T", &handle, |_| Facts::Unread).await;

    assert_eq!(resume_of(&r.daemon).await.as_deref(), Some("echo HI"));
    end(r, handle).await;
}

// S16: the freeze stops nothing else
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_under_shutdown_a_clean_exit_still_deletes_the_entry() {
    let (r, handle) = resumed("resume-freeze-clean").await;
    r.daemon.final_save().await;

    r.daemon.term_ended("T", Some(0)).await;

    assert!(!has_entry(&r.daemon).await);
    end(r, handle).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_under_shutdown_a_close_still_deletes_the_entry() {
    let (r, handle) = resumed("resume-freeze-close").await;
    r.daemon.final_save().await;

    r.daemon.close_term("T").await;

    assert!(!has_entry(&r.daemon).await);
    end(r, handle).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn s16_under_shutdown_a_clear_still_clears() {
    let (r, handle) = resumed("resume-freeze-clear").await;
    r.daemon.final_save().await;

    assert_eq!(r.daemon.set_resume(None, "T", None).await, Ok(()));

    assert_eq!(resume_of(&r.daemon).await, None);
    assert!(has_entry(&r.daemon).await);
    end(r, handle).await;
}

// S28b
#[tokio::test]
async fn s28b_a_command_is_checked_before_its_holder() {
    let daemon = Daemon::new(tmp_dir("resume-no-holder").join("state.json")).await.unwrap();
    daemon.terms.lock().await.insert("T".into(), TermHandle::detached());

    assert_eq!(
        daemon.set_resume(None, "T", Some("echo HI".into())).await,
        Err("no process to tie the resume command to in T".into())
    );
    assert_eq!(
        daemon.set_resume(None, "T", Some("echo a\necho b".into())).await,
        Err("resume command refused: a control character".into())
    );
}

// D3: a signal exit drops the command as any failed exit does.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_signal_exit_drops_the_command_and_keeps_the_entry() {
    let (r, handle) = resumed("resume-signal").await;

    r.daemon.term_ended("T", None).await;

    assert_eq!(resume_of(&r.daemon).await, None);
    assert!(has_entry(&r.daemon).await);
    end(r, handle).await;
}

// D4: the freeze is set before the shutdown save reads the cwds, so a drop
// that comes while the save waits on a held read is stopped.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_drop_during_the_shutdown_save_is_stopped() {
    let mut r = rig_with("resume-save-race", None, Duration::from_secs(30)).await;
    spawn(&r.daemon, "T", &["/bin/sh", "-c", "read _"], SpawnOpts { cwd: Some(&r.dir), ..Default::default() }).await;
    let handle = r.daemon.term("T").await.expect("T runs");
    eventually("T's first pid_cwd", || r.fs.calls(Call::PidCwd) >= 1).await;
    assert_eq!(r.daemon.set_resume(None, "T", Some("echo HI".into())).await, Ok(()));
    let before = r.fs.calls(Call::PidCwd);
    r.fs.hold_pid(pid_of(&r.daemon, "T").await);

    let daemon = r.daemon.clone();
    let save = tokio::spawn(async move { daemon.final_save().await });
    eventually("the save's cwd read", || r.fs.calls(Call::PidCwd) > before).await;
    r.daemon.check_resume("T", &handle, gone).await;
    r.release();
    within(save).await;

    assert_eq!(resume_of(&r.daemon).await.as_deref(), Some("echo HI"));
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(r.tmp.join("state.json")).unwrap()).unwrap();
    assert_eq!(saved["boards"][0]["term_records"]["T"]["resume"]["cmd"], "echo HI");
    end(r, handle).await;
}

// The poll checks the holder before its `continue` on a failed leader read:
// a handle that no process holds has no leader.
#[tokio::test]
async fn the_poll_drops_a_gone_holders_command_with_no_leader() {
    let daemon = Daemon::new(tmp_dir("resume-no-leader").join("state.json")).await.unwrap();
    let handle = TermHandle::detached();
    assert_eq!(handle.foreground_pid(), None);
    daemon.terms.lock().await.insert("T".into(), handle.clone());
    daemon.term_boards.lock().await.insert("T".into(), "board-0".into());
    {
        let mut boards = daemon.boards.lock().await;
        let record = tarmac_protocol::TermRecord { last_cwd: None, resume: Some(tarmac_protocol::ResumeRecord { cmd: "echo HI".into() }) };
        boards.known_registry_mut("board-0").unwrap().term_records.insert("T".into(), record);
        handle.hold_resume(crate::reports::Holder::Agent { pid: std::process::id() as Pid, started: 1 });
    }

    let poll = tokio::spawn(crate::term::proc_loop(daemon.clone(), "T".into(), handle.clone()));
    eventually_async("the drop", || async { resume_of(&daemon).await.is_none() }).await;
    daemon.terms.lock().await.remove("T");
    poll.abort();
}
