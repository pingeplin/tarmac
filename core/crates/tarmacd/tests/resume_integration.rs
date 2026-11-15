// Spec 2611.0011: a terminal's resume command, its holder, its drops and its
// survival of a daemon restart. A command set from inside a pty is sent by
// `nc` (`TestDaemon::nc_resume`); every shell is `/bin/sh -il` with a temp
// `HOME`, so no rc file of the user runs.

mod common;

use std::time::{Duration, Instant};

use common::{Conn, FrameLog, Restore, Spawn, TestDaemon, canon_dir, is_term_resume, signal_and_wait, term_records};
use serde_json::{Value, json};
use tarmac_protocol::Msg;

/// The `ack` frame's payload, as the agent's pty shows it.
const ACK: &[u8] = &[0x81, 0xa1, 0x74, 0xa3, 0x61, 0x63, 0x6b];

/// Three times the daemon's 150 ms save debounce: a save that is due has
/// landed by its end.
const SAVE_WINDOW: Duration = Duration::from_millis(450);

#[track_caller]
fn assert_ack(answer: Msg) {
    assert!(matches!(answer, Msg::Ack), "expected ack, got {answer:?}");
}

/// A drained app connection with a login shell `term_id` at its prompt.
fn shell_at_prompt(daemon: &TestDaemon, term_id: &str, opts: Spawn, log: &mut FrameLog) -> Conn {
    let mut app = daemon.connect_app_drained();
    app.spawn_term_with(term_id, &[], Spawn { login_shell: true, ..opts });
    app.log_until_output(log, term_id, 0, b"$ ");
    app
}

/// Types, at `term_id`'s prompt, a background agent that sets `cmd`, prints
/// `SENT` and lives `secs` more; returns once `SENT` shows, with the ack.
fn agent_sets(daemon: &TestDaemon, app: &mut Conn, log: &mut FrameLog, term_id: &str, cmd: &str, secs: u32) -> Instant {
    let nc = daemon.nc_resume(&format!("set-{}", log.len()), term_id, cmd);
    let start = log.len();
    app.type_line(term_id, &format!("/bin/zsh -f -c '{nc}; echo SE\"\"NT; sleep {secs}' &"));
    let sent = app.log_until_output(log, term_id, start, b"SENT");
    assert!(log.output_index_containing(term_id, start, ACK).is_some(), "the agent got no ack");
    log.0[sent].at
}

fn saved_resume(v: &Value, term_id: &str) -> Value {
    term_records(v, 0)[term_id]["resume"].clone()
}

fn wait_saved(daemon: &TestDaemon, term_id: &str, want: Value) {
    daemon.wait_for_state(&format!("{term_id}'s resume saved as {want}"), |v| saved_resume(v, term_id) == want);
}

/// The no-save check: the same inode one second later.
fn assert_no_save(daemon: &TestDaemon, kept: u64) {
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(daemon.state_inode(), kept, "the state was saved");
}

/// Probes until the restore satisfies `done`, to `deadline`; the newest
/// connection and its restore.
fn probe_until(daemon: &TestDaemon, what: &str, deadline: Instant, done: impl Fn(&Restore) -> bool) -> (Conn, Restore) {
    loop {
        let (app, restore) = daemon.probe();
        if done(&restore) {
            return (app, restore);
        }
        assert!(Instant::now() < deadline, "the restore never showed {what}: {:?}", restore.term_records);
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// A shell `T` whose agent has set `echo HI` and lives `secs` more.
fn set_by_agent(daemon: &TestDaemon, secs: u32) -> (Conn, FrameLog, Instant) {
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(daemon, "T", Spawn::default(), &mut log);
    let sent = agent_sets(daemon, &mut app, &mut log, "T", "echo HI", secs);
    (app, log, sent)
}

// S1, S2
#[test]
fn s1_s2_an_agent_sets_the_command_and_its_exit_drops_it() {
    let daemon = TestDaemon::start_sh();
    let (_app, _log, sent) = set_by_agent(&daemon, 3);

    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T"), Some("echo HI"));
    wait_saved(&daemon, "T", json!({"cmd": "echo HI"}));
    let entry = term_records(&daemon.state_json(), 0)["T"].clone();
    assert!(entry.as_object().unwrap().keys().all(|k| k == "last_cwd" || k == "resume"), "{entry}");

    let (_app, restore) = probe_until(&daemon, "no resume", sent + Duration::from_secs(6), |r| r.resume_cmd("T").is_none());
    assert!(restore.last_cwd("T").is_some(), "{:?}", restore.term_records);
    assert_eq!(restore.live_terms, ["T"]);
    wait_saved(&daemon, "T", Value::Null);
    assert!(!term_records(&daemon.state_json(), 0)["T"]["last_cwd"].is_null());
}

/// S3: a command whose agent still runs survives the daemon's death.
fn survives(kill: impl FnOnce(&mut TestDaemon)) {
    let mut daemon = TestDaemon::start_sh();
    let _set = set_by_agent(&daemon, 30);
    wait_saved(&daemon, "T", json!({"cmd": "echo HI"}));

    kill(&mut daemon);

    let (_app, restore) = daemon.probe();
    assert!(restore.live_terms.is_empty());
    assert_eq!(restore.resume_cmd("T"), Some("echo HI"));
}

// S3
#[test]
fn s3_a_sigkilled_daemon_leaves_the_command_for_the_next() {
    survives(TestDaemon::restart);
}

// S3
#[test]
fn s3_a_sigtermed_daemon_saves_the_command_for_the_next() {
    survives(|daemon| {
        let status = signal_and_wait(&mut daemon.child, libc::SIGTERM);
        assert!(status.success(), "the daemon exited with {status:?}");
        daemon.relaunch();
    });
}

/// A daemon seeded with `T`'s record in `a` with `echo HI`, and `T2` spawned
/// as its successor at its prompt; the probe that shows the move.
fn moved(log: &mut FrameLog) -> (TestDaemon, String, Conn) {
    let tmp = common::temp_dir();
    let a = canon_dir(&tmp.join("a"));
    let home = canon_dir(&tmp.join("home"));
    let seeded = json!({
        "boards": [{"board_id": "board-0", "tiles": [{"kind": "term", "term_id": "T"}],
                    "term_records": {"T": {"last_cwd": a, "resume": {"cmd": "echo HI"}}}}],
        "active": "board-0",
    });
    let daemon = TestDaemon::start_seeded_with(&seeded, |cmd| {
        cmd.env("SHELL", "/bin/sh").env("HOME", &home);
    });
    shell_at_prompt(&daemon, "T2", Spawn { cwd: Some(a.clone()), succeeds: Some("T".into()), ..Default::default() }, log);
    let (app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T2"), Some("echo HI"));
    assert!(!restore.term_records.contains_key("T"), "{:?}", restore.term_records);
    (daemon, a, app)
}

// S4
#[test]
fn s4_a_moved_command_is_dropped_by_typed_input_only() {
    let mut log = FrameLog::default();
    let (daemon, a, mut app) = moved(&mut log);

    app.send(&Msg::Input { term_id: "T2".into(), bytes: b"x".to_vec(), typed: false });
    std::thread::sleep(Duration::from_secs(1));
    let (mut app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T2"), Some("echo HI"), "an untyped input dropped it");

    app.send(&Msg::Input { term_id: "T2".into(), bytes: b"\r".to_vec(), typed: true });

    daemon.wait_for_state("T2 with no resume", |v| {
        let record = &term_records(v, 0)["T2"];
        record["resume"].is_null() && record["last_cwd"] == json!(a)
    });
}

// S4b
#[test]
fn s4b_a_set_over_a_moved_command_is_held() {
    let mut log = FrameLog::default();
    let (daemon, _a, mut app) = moved(&mut log);
    agent_sets(&daemon, &mut app, &mut log, "T2", "echo HO", 30);

    app.send(&Msg::Input { term_id: "T2".into(), bytes: b"\r".to_vec(), typed: true });
    std::thread::sleep(Duration::from_secs(1));

    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T2"), Some("echo HO"));
}

// S13
#[test]
fn s13_typed_input_does_not_drop_a_held_command() {
    let daemon = TestDaemon::start_sh();
    let (mut app, _log, _) = set_by_agent(&daemon, 30);

    app.send(&Msg::Input { term_id: "T".into(), bytes: b"\r".to_vec(), typed: true });
    std::thread::sleep(Duration::from_secs(1));

    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T"), Some("echo HI"));
}

// S14
#[test]
fn s14_a_command_set_at_the_prompt_lasts_while_the_shell_lives() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(&daemon, "T", Spawn::default(), &mut log);
    let nc = daemon.nc_resume("prompt", "T", "echo HI");
    let start = log.len();
    app.type_line("T", &format!("{nc}; echo BA\"\"CK"));
    app.log_until_output(&mut log, "T", start, b"BACK");
    assert!(log.output_index_containing("T", start, ACK).is_some(), "no ack");

    app.type_line("T", "sleep 2");
    std::thread::sleep(Duration::from_secs(3));

    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T"), Some("echo HI"));
}

/// S15: `T` with a command held by a live agent ends with `exit <code>`.
fn ends_with(code: i64) -> TestDaemon {
    let daemon = TestDaemon::start_sh();
    let (mut app, _log, _) = set_by_agent(&daemon, 30);
    wait_saved(&daemon, "T", json!({"cmd": "echo HI"}));
    assert!(!term_records(&daemon.state_json(), 0)["T"]["last_cwd"].is_null());

    app.type_line("T", &format!("exit {code}"));

    assert_eq!(app.recv_exit(), ("T".to_string(), Some(code)));
    daemon
}

// S15
#[test]
fn s15_a_failed_exit_drops_the_command_and_keeps_the_folder() {
    let daemon = ends_with(3);
    daemon.wait_for_state("T with no resume", |v| {
        let record = &term_records(v, 0)["T"];
        record["resume"].is_null() && !record["last_cwd"].is_null()
    });
}

// S15
#[test]
fn s15_a_clean_exit_drops_the_entry() {
    let daemon = ends_with(0);
    daemon.wait_for_state("no entry for T", |v| term_records(v, 0)["T"].is_null());
}

// S17
#[test]
fn s17_a_repeat_of_the_same_command_does_not_save() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(&daemon, "T", Spawn::default(), &mut log);
    let (first, again) = (daemon.nc_resume("first", "T", "echo HI"), daemon.nc_resume("again", "T", "echo HI"));
    let start = log.len();
    app.type_line("T", &format!("/bin/zsh -f -c '{first}; echo SE\"\"NT; sleep 1; {again}; echo AG\"\"AIN; sleep 30' &"));

    let sent = app.log_until_output(&mut log, "T", start, b"SENT");
    wait_saved(&daemon, "T", json!({"cmd": "echo HI"}));
    std::thread::sleep(SAVE_WINDOW);
    let kept = daemon.state_inode();
    let read_after = log.0[sent].at.elapsed();
    assert!(read_after < Duration::from_secs(1), "the inode was read {read_after:?} after SENT, maybe after the repeat");
    let at = app.log_until_output(&mut log, "T", start, b"AGAIN");

    let mut out = Vec::new();
    for logged in &log.0[start..=at] {
        if let Msg::Output { term_id, bytes } = &logged.msg
            && term_id == "T"
        {
            out.extend_from_slice(bytes);
        }
    }
    assert_eq!(out.windows(ACK.len()).filter(|w| *w == ACK).count(), 2, "two acks");
    assert_no_save(&daemon, kept);

    agent_sets(&daemon, &mut app, &mut log, "T", "echo HO", 30);
    wait_saved(&daemon, "T", json!({"cmd": "echo HO"}));
    assert_ne!(daemon.state_inode(), kept, "the control: a set that changes the command saves");
}

// S18
#[test]
fn s18_a_clear_saves_once_and_a_second_clear_does_not() {
    let daemon = TestDaemon::start_sh();
    let _set = set_by_agent(&daemon, 30);
    wait_saved(&daemon, "T", json!({"cmd": "echo HI"}));

    assert_ack(Conn::cli_resume(&daemon.sock, "T", None));
    wait_saved(&daemon, "T", Value::Null);
    std::thread::sleep(SAVE_WINDOW);
    let kept = daemon.state_inode();

    assert_ack(Conn::cli_resume(&daemon.sock, "T", None));
    assert_no_save(&daemon, kept);
}

// S28
#[test]
fn s28_the_daemon_refuses_an_unknown_terminal_then_a_bad_command() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.spawn_term("T", &["/bin/sh", "-c", "echo UP; read _"]);
    app.recv_output_containing("T", "UP");

    let refused = |cmd: &str| Conn::cli_resume(&daemon.sock, "T", Some(cmd));
    assert_eq!(Conn::cli_resume(&daemon.sock, "nobody", Some("echo HI")), Msg::Err { msg: "unknown terminal: nobody".into() });
    assert_eq!(
        Conn::cli_resume(&daemon.sock, "nobody", Some("echo a\necho b")),
        Msg::Err { msg: "unknown terminal: nobody".into() }
    );
    for (cmd, cause) in [
        ("echo a\necho b", "a control character"),
        ("echo \u{1b}[2J", "a control character"),
        ("echo \u{202e}x", "an invisible format character"),
        ("", "empty"),
        ("   ", "empty"),
        (&"a".repeat(257), "over 256 characters"),
    ] {
        assert_eq!(refused(cmd), Msg::Err { msg: format!("resume command refused: {cause}") }, "{cmd:?}");
    }

    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T"), None);
}

// Spec 2611.0015: the daemon pushes `term_resume` at each change of a live
// terminal's command, and the app session's `resume` clears an unclaimed one.

const QUIET: Duration = Duration::from_secs(1);

fn term_resume(term_id: &str, cmd: Option<&str>) -> Msg {
    Msg::TermResume { term_id: term_id.into(), cmd: cmd.map(str::to_string) }
}

/// The first `term_resume` in `log` from `from` on, reading more frames into
/// it until one comes; its index.
fn await_term_resume(app: &mut Conn, log: &mut FrameLog, from: usize) -> usize {
    if let Some(i) = (from..log.len()).find(|&i| is_term_resume(&log.0[i].msg)) {
        return i;
    }
    app.log_until(log, "a term_resume", is_term_resume)
}

#[track_caller]
fn assert_no_term_resume(app: &mut Conn, log: &FrameLog, from: usize) {
    let early: Vec<_> = log.0[from..].iter().filter(|l| is_term_resume(&l.msg)).map(|l| &l.msg).collect();
    assert!(early.is_empty(), "pushed: {early:?}");
    assert!(common::none_within(app, QUIET, is_term_resume), "a term_resume came");
}

// S11
#[test]
fn s11_a_set_pushes_the_command_and_a_repeat_of_it_does_not() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(&daemon, "T", Spawn::default(), &mut log);

    let start = log.len();
    agent_sets(&daemon, &mut app, &mut log, "T", "echo HI", 30);
    let at = await_term_resume(&mut app, &mut log, start);
    assert_eq!(log.0[at].msg, term_resume("T", Some("echo HI")));

    let again = log.len();
    agent_sets(&daemon, &mut app, &mut log, "T", "echo HI", 30);
    assert_no_term_resume(&mut app, &log, again);

    let changed = log.len();
    agent_sets(&daemon, &mut app, &mut log, "T", "echo HO", 30);
    let at = await_term_resume(&mut app, &mut log, changed);
    assert_eq!(log.0[at].msg, term_resume("T", Some("echo HO")));

    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    let restore = Restore::from(app.recv_until("the restore", |m| matches!(m, Msg::Restore { .. })));
    assert_eq!(restore.live_terms, ["T"]);
    assert_eq!(restore.resume_cmd("T"), Some("echo HO"));
}

// S12
#[test]
fn s12_a_cli_clear_pushes_once() {
    let daemon = TestDaemon::start_sh();
    let (mut app, mut log, _) = set_by_agent(&daemon, 30);
    await_term_resume(&mut app, &mut log, 0);

    let start = log.len();
    assert_ack(Conn::cli_resume(&daemon.sock, "T", None));
    let at = await_term_resume(&mut app, &mut log, start);
    assert_eq!(log.0[at].msg, term_resume("T", None));

    let again = log.len();
    assert_ack(Conn::cli_resume(&daemon.sock, "T", None));
    assert_no_term_resume(&mut app, &log, again);
}

// S13
#[test]
fn s13_the_polls_drop_pushes_a_clear() {
    let daemon = TestDaemon::start_sh();
    let (mut app, mut log, sent) = set_by_agent(&daemon, 3);
    let set = await_term_resume(&mut app, &mut log, 0);
    assert_eq!(log.0[set].msg, term_resume("T", Some("echo HI")));

    let deadline = sent + Duration::from_secs(6);
    let clear = app.recv_within(deadline.saturating_duration_since(Instant::now()), is_term_resume);
    assert_eq!(clear, Some(term_resume("T", None)));
}

/// A daemon seeded with `T`'s record with `echo HI`, and the app connection
/// that spawned `T2` as its successor, with every frame since in `log`.
fn moved_on_one_connection(log: &mut FrameLog) -> (TestDaemon, Conn) {
    let tmp = common::temp_dir();
    let a = canon_dir(&tmp.join("a"));
    let home = canon_dir(&tmp.join("home"));
    let seeded = json!({
        "boards": [{"board_id": "board-0", "tiles": [{"kind": "term", "term_id": "T"}],
                    "term_records": {"T": {"last_cwd": a, "resume": {"cmd": "echo HI"}}}}],
        "active": "board-0",
    });
    let daemon = TestDaemon::start_seeded_with(&seeded, |cmd| {
        cmd.env("SHELL", "/bin/sh").env("HOME", &home);
    });
    let app = shell_at_prompt(&daemon, "T2", Spawn { cwd: Some(a), succeeds: Some("T".into()), ..Default::default() }, log);
    (daemon, app)
}

// S14
#[test]
fn s14_the_move_pushes_nothing_and_the_typed_drop_pushes_a_clear() {
    let mut log = FrameLog::default();
    let (_daemon, mut app) = moved_on_one_connection(&mut log);
    assert_no_term_resume(&mut app, &log, 0);

    let start = log.len();
    app.send(&Msg::Input { term_id: "T2".into(), bytes: b"\r".to_vec(), typed: true });
    let at = await_term_resume(&mut app, &mut log, start);
    assert_eq!(log.0[at].msg, term_resume("T2", None));
}

// S15
#[test]
fn s15_the_app_clear_drops_an_unclaimed_record_and_a_cmd_from_the_app_sets_none() {
    let mut log = FrameLog::default();
    let (daemon, mut app) = moved_on_one_connection(&mut log);

    let start = log.len();
    app.send(&Msg::Resume { term_id: "T2".into(), cmd: None });
    let at = await_term_resume(&mut app, &mut log, start);
    assert_eq!(log.0[at].msg, term_resume("T2", None));
    daemon.wait_for_state("T2 with no resume", |v| {
        let record = &term_records(v, 0)["T2"];
        !record.is_null() && record["resume"].is_null()
    });

    let set = log.len();
    app.send(&Msg::Resume { term_id: "T2".into(), cmd: Some("echo X".into()) });
    assert_no_term_resume(&mut app, &log, set);
    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T2"), None);
}

// S15
#[test]
fn s15_the_app_clear_never_drops_a_held_record() {
    let daemon = TestDaemon::start_sh();
    let (mut app, mut log, _) = set_by_agent(&daemon, 30);
    await_term_resume(&mut app, &mut log, 0);

    let start = log.len();
    app.send(&Msg::Resume { term_id: "T".into(), cmd: None });
    assert_no_term_resume(&mut app, &log, start);
    let (_app, restore) = daemon.probe();
    assert_eq!(restore.resume_cmd("T"), Some("echo HI"));
}

// S20
#[test]
fn s20_the_end_of_a_terminal_and_a_close_push_nothing() {
    let daemon = TestDaemon::start_sh();
    let (mut app, mut log, _) = set_by_agent(&daemon, 30);
    await_term_resume(&mut app, &mut log, 0);

    let start = log.len();
    app.type_line("T", "exit 3");
    app.log_until(&mut log, "T's exit", |m| common::is_exit_for(m, "T"));
    assert_no_term_resume(&mut app, &log, start);

    let opened = log.len();
    app.spawn_term_with("U", &[], Spawn::login_shell());
    app.log_until_output(&mut log, "U", opened, b"$ ");
    agent_sets(&daemon, &mut app, &mut log, "U", "echo HI", 30);
    let at = await_term_resume(&mut app, &mut log, opened);
    assert_eq!(log.0[at].msg, term_resume("U", Some("echo HI")), "the control: a set pushes");

    let closed = log.len();
    app.send(&Msg::TermClose { term_id: "U".into() });
    assert_no_term_resume(&mut app, &log, closed);
}

// S21
#[test]
fn s21_a_subscriber_never_gets_a_term_resume() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(&daemon, "T", Spawn::default(), &mut log);
    let (mut events, _) = common::subscriber(&daemon.sock, None, None);

    let start = log.len();
    agent_sets(&daemon, &mut app, &mut log, "T", "echo HI", 30);
    await_term_resume(&mut app, &mut log, start);
    assert!(common::none_within(&mut events, QUIET, is_term_resume), "the subscriber got a term_resume");

    app.type_line("T", "exit 3");
    let exit = events.recv_within(Duration::from_secs(5), |m| common::is_exit_for(m, "T"));
    assert!(exit.is_some(), "the control: the subscriber got no exit");
}

// S24
#[test]
fn s24_an_app_clear_for_an_unknown_terminal_changes_nothing() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let mut app = shell_at_prompt(&daemon, "T", Spawn::default(), &mut log);

    let start = log.len();
    app.send(&Msg::Resume { term_id: "nope".into(), cmd: None });
    assert_no_term_resume(&mut app, &log, start);

    let typed = log.len();
    app.type_line("T", "echo ST\"\"ILL");
    app.log_until_output(&mut log, "T", typed, b"STILL");

    let set = log.len();
    agent_sets(&daemon, &mut app, &mut log, "T", "echo HI", 30);
    let at = await_term_resume(&mut app, &mut log, set);
    assert_eq!(log.0[at].msg, term_resume("T", Some("echo HI")));
}
