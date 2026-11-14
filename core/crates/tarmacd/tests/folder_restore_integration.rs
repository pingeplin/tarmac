// Spec 2611.0007: each board's `term_records` keep a terminal's last cwd, so a
// cold spawn after a daemon restart opens in that folder.

mod common;

use std::path::Path;
use std::time::{Duration, Instant};

use common::{Conn, LONG, Restore, Spawn, TestDaemon, none_within, signal_and_wait, wait_exit};
use serde_json::{Value, json};
use tarmac_protocol::{Msg, Tile};

/// A job-control shell that reads no rc file (OQ1): each command runs in a
/// process group of its own, so the foreground pid changes.
const JOB_SHELL: &[&str] = &["/bin/zsh", "-f", "-i"];

fn canon_dir(path: &Path) -> String {
    std::fs::create_dir_all(path).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

fn plain(script: &str) -> Vec<String> {
    vec!["/bin/sh".into(), "-c".into(), script.into()]
}

fn spawn(app: &mut Conn, term_id: &str, argv: &[String], opts: Spawn) {
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    app.spawn_term_with(term_id, &argv, opts);
}

fn in_dir(dir: &str) -> Spawn {
    Spawn { cwd: Some(dir.into()), ..Default::default() }
}

fn last_cwd(restore: &Restore, term_id: &str) -> Option<String> {
    restore.term_records.get(term_id).and_then(|r| r.last_cwd.clone())
}

/// A new app connection, and the restore of the active board it gets.
fn probe(daemon: &TestDaemon) -> (Conn, Restore) {
    let mut app = daemon.connect_app();
    app.recv_board_list();
    let restore = app.recv_restore();
    (app, restore)
}

/// Probes until the active board's record of `term_id` has `want`.
fn probe_until_cwd(daemon: &TestDaemon, term_id: &str, want: &str) -> Conn {
    let deadline = Instant::now() + LONG;
    loop {
        let (app, restore) = probe(daemon);
        if last_cwd(&restore, term_id).as_deref() == Some(want) {
            return app;
        }
        assert!(Instant::now() < deadline, "the record of {term_id} never showed {want}: {:?}", restore.term_records);
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn term_tile(term_id: &str) -> Tile {
    Tile { kind: "term".into(), term_id: Some(term_id.into()), ..Default::default() }
}

fn send_layout(app: &mut Conn, term_ids: &[&str]) {
    app.send(&Msg::Layout {
        dock: vec![],
        tiles: term_ids.iter().map(|t| term_tile(t)).collect(),
        board: None,
        board_id: Some("board-0".into()),
    });
}

fn records(v: &Value, board: usize) -> Value {
    v["boards"][board]["term_records"].clone()
}

fn has_record(v: &Value, board: usize, term_id: &str) -> bool {
    !records(v, board)[term_id].is_null()
}

fn saved_cwd(v: &Value, board: usize, term_id: &str) -> Value {
    records(v, board)[term_id]["last_cwd"].clone()
}

fn board(id: &str, term_records: Value) -> Value {
    json!({"board_id": id, "tiles": [{"kind": "term", "term_id": "T"}], "term_records": term_records})
}

/// One board with `term_records`, as a daemon wrote it.
fn seeded(term_records: Value) -> Value {
    json!({"boards": [board("board-0", term_records)], "active": "board-0"})
}

/// board-0 active with no record, board-1 with `T`'s record.
fn seeded_on_board_1() -> Value {
    json!({"boards": [board("board-0", json!({})), board("board-1", json!({"T": {"last_cwd": "/seeded"}}))], "active": "board-0"})
}

fn input(app: &mut Conn, term_id: &str, line: &str) {
    app.send(&Msg::Input { term_id: term_id.into(), bytes: format!("{line}\n").into_bytes() });
}

fn wait_output(app: &mut Conn, term_id: &str, needle: &str) {
    let mut collected = Vec::new();
    app.collect_output_into(&mut collected, term_id, needle, needle.as_bytes());
}

/// The pid of `term_id`'s next `term_proc` that `pred` takes.
fn proc_pid(app: &mut Conn, term_id: &str, what: &str, pred: impl Fn(&str, i64) -> bool) -> i64 {
    let msg = app.recv_until(what, |m| {
        matches!(m, Msg::TermProc { term_id: t, name, pid: Some(pid) } if t == term_id && pred(name, *pid))
    });
    let Msg::TermProc { pid: Some(pid), .. } = msg else { unreachable!() };
    pid
}

/// A job-control shell `T` in `a`, whose record a probe shows; the shell's
/// first pid and the newest connection.
fn job_shell_recorded(daemon: &TestDaemon, a: &str) -> (Conn, i64) {
    let mut app = daemon.connect_app_drained();
    let argv: Vec<String> = JOB_SHELL.iter().map(|s| s.to_string()).collect();
    spawn(&mut app, "T", &argv, in_dir(a));
    let first = proc_pid(&mut app, "T", "T's first term_proc", |_, _| true);
    (probe_until_cwd(daemon, "T", a), first)
}

/// `cd b && sleep 3` in `T`, to the `term_proc` of the sleep. The new pid is
/// the precondition of a job-control shell.
fn cd_and_sleep(app: &mut Conn, b: &str, first: i64) {
    input(app, "T", &format!("cd '{b}' && sleep 3"));
    let pid = proc_pid(app, "T", "the sleep's term_proc", |name, _| name == "sleep");
    assert_ne!(pid, first, "the shell gave the sleep no process group of its own");
}

// S1
#[test]
fn a_command_records_the_cwd_with_no_shutdown() {
    let daemon = TestDaemon::start();
    let (a, b) = (canon_dir(&daemon.dir.join("a")), canon_dir(&daemon.dir.join("b")));
    let (mut app, first) = job_shell_recorded(&daemon, &a);

    cd_and_sleep(&mut app, &b, first);

    probe_until_cwd(&daemon, "T", &b);
}

// S1: a new pid with the same name is read too.
#[test]
fn a_new_pid_with_the_same_name_records_the_cwd() {
    let daemon = TestDaemon::start();
    let (a, b, c) = (
        canon_dir(&daemon.dir.join("a")),
        canon_dir(&daemon.dir.join("b")),
        canon_dir(&daemon.dir.join("c")),
    );
    let (mut app, first) = job_shell_recorded(&daemon, &a);

    input(&mut app, "T", &format!("cd '{b}' && sleep 2 && cd '{c}' && sleep 30"));
    let pid = proc_pid(&mut app, "T", "the first sleep's term_proc", |name, _| name == "sleep");
    assert_ne!(pid, first, "the shell gave the sleep no process group of its own");

    // The second sleep runs 30 s, so only a read at its own pid shows c.
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        let (_app, restore) = probe(&daemon);
        if last_cwd(&restore, "T").as_deref() == Some(c.as_str()) {
            break;
        }
        assert!(Instant::now() < deadline, "the second sleep's cwd was never recorded: {:?}", restore.term_records);
        std::thread::sleep(Duration::from_millis(100));
    }
}

// S7
#[test]
fn a_cwd_change_does_not_save() {
    let daemon = TestDaemon::start();
    let (a, b) = (canon_dir(&daemon.dir.join("a")), canon_dir(&daemon.dir.join("b")));
    let (mut app, first) = job_shell_recorded(&daemon, &a);
    send_layout(&mut app, &["T"]);
    daemon.wait_for_state("the layout of T", |v| v["boards"][0]["tiles"][0]["term_id"] == json!("T"));
    std::thread::sleep(Duration::from_millis(500));
    let kept = std::fs::read(daemon.state_file()).unwrap();

    cd_and_sleep(&mut app, &b, first);
    let mut app = probe_until_cwd(&daemon, "T", &b);
    std::thread::sleep(Duration::from_secs(1));

    assert_eq!(std::fs::read(daemon.state_file()).unwrap(), kept, "a cwd change saved the state");
    send_layout(&mut app, &["T"]);
    daemon.wait_for_state("B saved by the next layout", |v| saved_cwd(v, 0, "T") == json!(b));
}

/// A plain shell `T` in `a` that moves to `b` on a line, recorded in `a`,
/// then moved: the newest connection.
fn moved_at_idle(daemon: &TestDaemon, a: &str, b: &str) -> Conn {
    let mut app = daemon.connect_app_drained();
    spawn(&mut app, "T", &plain(&format!("read _; cd '{b}' && echo MOVED; read _")), in_dir(a));
    proc_pid(&mut app, "T", "T's first term_proc", |_, _| true);
    let mut app = probe_until_cwd(daemon, "T", a);
    input(&mut app, "T", "go");
    wait_output(&mut app, "T", "MOVED");
    app
}

// S2
#[test]
fn an_idle_cd_is_saved_at_shutdown() {
    let mut daemon = TestDaemon::start();
    let (a, b) = (canon_dir(&daemon.dir.join("a")), canon_dir(&daemon.dir.join("b")));
    let _app = moved_at_idle(&daemon, &a, &b);

    let status = signal_and_wait(&mut daemon.child, libc::SIGTERM);

    assert!(status.success(), "the daemon exited with {status:?}");
    let saved = records(&daemon.state_json(), 0)["T"].clone();
    assert_eq!(saved, json!({"last_cwd": b}), "the entry has last_cwd and no other key");
    daemon.relaunch();
    let (_app, restore) = probe(&daemon);
    assert_eq!(last_cwd(&restore, "T"), Some(b));
}

/// S18: the state is saved before the socket goes.
fn saved_before_the_socket_goes(sig: libc::c_int) {
    let mut daemon = TestDaemon::start();
    let (a, b) = (canon_dir(&daemon.dir.join("a")), canon_dir(&daemon.dir.join("b")));
    let _app = moved_at_idle(&daemon, &a, &b);

    unsafe { libc::kill(daemon.child.id() as libc::pid_t, sig) };
    let deadline = Instant::now() + LONG;
    while daemon.sock.exists() {
        assert!(Instant::now() < deadline, "the socket never went");
        std::thread::sleep(Duration::from_millis(2));
    }
    let state: Value = serde_json::from_slice(&std::fs::read(daemon.state_file()).unwrap()).expect("the state parses");

    assert_eq!(saved_cwd(&state, 0, "T"), json!(b));
    let status = wait_exit(&mut daemon.child);
    assert!(status.success(), "the daemon exited with {status:?}");
}

#[test]
fn sigterm_saves_before_the_socket_goes() {
    saved_before_the_socket_goes(libc::SIGTERM);
}

#[test]
fn sighup_saves_before_the_socket_goes() {
    saved_before_the_socket_goes(libc::SIGHUP);
}

#[test]
fn sigint_saves_before_the_socket_goes() {
    saved_before_the_socket_goes(libc::SIGINT);
}

// S3
#[test]
fn succeeds_moves_the_record_to_the_new_term() {
    let tmp = common::temp_dir();
    let b = canon_dir(&tmp.join("b"));
    let daemon = TestDaemon::start_seeded(&seeded(json!({"T": {"last_cwd": b}})));
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "T2", &plain("pwd -P; read _"), Spawn { succeeds: Some("T".into()), ..in_dir(&b) });

    wait_output(&mut app, "T2", &b);
    let (_app, restore) = probe(&daemon);
    assert!(restore.term_records.contains_key("T2"), "{:?}", restore.term_records);
    assert!(!restore.term_records.contains_key("T"), "{:?}", restore.term_records);
    daemon.wait_for_state("the move saved", |v| has_record(v, 0, "T2") && !has_record(v, 0, "T"));
    let _ = std::fs::remove_dir_all(tmp);
}

// S6
#[test]
fn a_layout_keeps_the_records() {
    let daemon = TestDaemon::start_seeded(&seeded(json!({"T": {"last_cwd": "/seeded"}})));
    let mut app = daemon.connect_app_drained();

    send_layout(&mut app, &["X"]);

    daemon.wait_for_state("the layout of X", |v| v["boards"][0]["tiles"][0]["term_id"] == json!("X"));
    assert_eq!(saved_cwd(&daemon.state_json(), 0, "T"), json!("/seeded"));
    let (_app, restore) = probe(&daemon);
    assert_eq!(last_cwd(&restore, "T").as_deref(), Some("/seeded"));
}

/// Plain shells, each in `daemon.dir`, whose records a layout save has written.
fn saved_shells(daemon: &TestDaemon, shells: &[(&str, &str)]) -> Conn {
    let mut app = daemon.connect_app_drained();
    let dir = canon_dir(&daemon.dir);
    for (term_id, script) in shells {
        spawn(&mut app, term_id, &plain(script), in_dir(&dir));
        proc_pid(&mut app, term_id, "the shell's term_proc", |_, _| true);
    }
    let ids: Vec<&str> = shells.iter().map(|(t, _)| *t).collect();
    for term_id in &ids {
        app = probe_until_cwd(daemon, term_id, &dir);
    }
    send_layout(&mut app, &ids);
    daemon.wait_for_state("the records saved", |v| ids.iter().all(|t| saved_cwd(v, 0, t) == json!(dir)));
    app
}

// S8
#[test]
fn term_close_deletes_the_record() {
    let daemon = TestDaemon::start();
    let mut app = saved_shells(&daemon, &[("T", "read _")]);

    app.send(&Msg::TermClose { term_id: "T".into() });

    assert_eq!(app.recv_exit().0, "T");
    let (_app, restore) = probe(&daemon);
    assert!(!restore.term_records.contains_key("T"), "{:?}", restore.term_records);
    daemon.wait_for_state("no record of T", |v| !has_record(v, 0, "T"));
}

// S9
#[test]
fn a_clean_exit_deletes_the_record_and_a_failure_keeps_it() {
    let daemon = TestDaemon::start();
    let shells = [("T1", "read _; exit 0"), ("T2", "read _; exit 3"), ("T3", "read _; kill -9 $$")];
    let mut app = saved_shells(&daemon, &shells);

    for (term_id, _) in &shells {
        input(&mut app, term_id, "go");
    }

    let mut exits: Vec<(String, Option<i64>)> = (0..3).map(|_| app.recv_exit()).collect();
    exits.sort();
    assert_eq!(exits, vec![("T1".into(), Some(0)), ("T2".into(), Some(3)), ("T3".into(), None)]);
    let (_app, restore) = probe(&daemon);
    let kept: Vec<&String> = restore.term_records.keys().collect();
    assert_eq!(kept, ["T2", "T3"]);
    daemon.wait_for_state("no record of T1", |v| !has_record(v, 0, "T1") && has_record(v, 0, "T2") && has_record(v, 0, "T3"));
}

// S26
#[test]
fn term_close_deletes_the_record_of_a_term_that_is_not_live() {
    let daemon = TestDaemon::start_seeded(&seeded_on_board_1());
    let mut app = daemon.connect_app_drained();
    app.send(&Msg::TermClose { term_id: "nobody".into() });
    assert!(none_within(&mut app, Duration::from_secs(1), |m| matches!(m, Msg::Err { .. })), "an err frame");

    app.send(&Msg::TermClose { term_id: "T".into() });

    daemon.wait_for_state("no record of T", |v| !has_record(v, 0, "T") && !has_record(v, 1, "T"));
    let restore = app.switch_to("board-1");
    assert!(!restore.term_records.contains_key("T"), "{:?}", restore.term_records);
}

// S13
#[test]
fn an_old_state_file_loads_with_no_records_and_saves_none() {
    let old = json!({"boards": [{"board_id": "board-0", "tiles": [{"kind": "term", "term_id": "T"}]}, {"board_id": "board-1"}], "active": "board-0"});
    let daemon = TestDaemon::start_seeded(&old);
    let (mut app, restore) = probe(&daemon);
    assert!(restore.term_records.is_empty());

    send_layout(&mut app, &["X"]);

    daemon.wait_for_state("the layout of X", |v| v["boards"][0]["tiles"][0]["term_id"] == json!("X"));
    let saved = daemon.state_json();
    for b in saved["boards"].as_array().unwrap() {
        assert!(b.get("term_records").is_none(), "{b}");
    }
}

// S14
#[test]
fn a_gone_folder_spawns_in_home() {
    let home_dir = common::temp_dir();
    let home = canon_dir(&home_dir);
    let gone = home_dir.join("gone").to_string_lossy().into_owned();
    let daemon = TestDaemon::start_seeded_with(&seeded(json!({"T": {"last_cwd": gone}})), |c| {
        c.env("HOME", &home);
    });
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "T2", &plain("pwd -P; read _"), Spawn { succeeds: Some("T".into()), ..in_dir(&gone) });

    wait_output(&mut app, "T2", &home);
    assert!(none_within(&mut app, Duration::from_secs(1), |m| matches!(m, Msg::Err { .. })), "an err frame");
    let (_app, restore) = probe(&daemon);
    assert!(!restore.term_records.contains_key("T"), "{:?}", restore.term_records);
    let _ = std::fs::remove_dir_all(home_dir);
}

// S15 (a)
#[test]
fn succeeds_naming_a_live_term_moves_nothing() {
    let daemon = TestDaemon::start();
    let mut app = saved_shells(&daemon, &[("L", "read _")]);

    spawn(&mut app, "X", &plain("echo XUP; read _"), Spawn { succeeds: Some("L".into()), ..Default::default() });

    wait_output(&mut app, "X", "XUP");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| matches!(m, Msg::Err { .. })), "an err frame");
    let (_app, restore) = probe(&daemon);
    assert!(restore.term_records.contains_key("L"), "{:?}", restore.term_records);
}

// S15 (b)
#[test]
fn succeeds_naming_an_id_with_no_record_is_no_error() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "X", &plain("echo XUP; read _"), Spawn { succeeds: Some("nobody".into()), ..Default::default() });

    wait_output(&mut app, "X", "XUP");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| matches!(m, Msg::Err { .. })), "an err frame");
}

// S16
#[test]
fn a_failed_spawn_moves_nothing() {
    let daemon = TestDaemon::start_seeded(&seeded(json!({"T": {"last_cwd": "/seeded"}})));
    let mut app = daemon.connect_app_drained();
    spawn(&mut app, "X", &plain("echo XUP; read _"), Spawn::default());
    wait_output(&mut app, "X", "XUP");

    spawn(&mut app, "X", &plain("read _"), Spawn { succeeds: Some("T".into()), ..Default::default() });

    let err = app.recv_until("err", |m| matches!(m, Msg::Err { .. }));
    assert_eq!(err, Msg::Err { msg: "term_id already in use: X".into() });
    let (_app, restore) = probe(&daemon);
    assert_eq!(last_cwd(&restore, "T").as_deref(), Some("/seeded"));
}

// S16: a spawn that fails after its id was found free moves nothing.
#[test]
fn a_spawn_that_cannot_exec_moves_nothing() {
    let daemon = TestDaemon::start_seeded(&seeded(json!({"T": {"last_cwd": "/seeded"}})));
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "X", &["/nonexistent/tarmac-no-such-shell".to_string()], Spawn { succeeds: Some("T".into()), ..Default::default() });

    let err = app.recv_until("err", |m| matches!(m, Msg::Err { .. }));
    assert!(matches!(&err, Msg::Err { msg } if msg.starts_with("spawn failed")), "{err:?}");
    let (_app, restore) = probe(&daemon);
    assert_eq!(last_cwd(&restore, "T").as_deref(), Some("/seeded"));
    assert!(!restore.term_records.contains_key("X"), "{:?}", restore.term_records);
}

// S20
#[test]
fn succeeds_does_not_reach_another_board() {
    let daemon = TestDaemon::start_seeded(&seeded_on_board_1());
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "T2", &plain("echo UP; read _"), Spawn { succeeds: Some("T".into()), ..Spawn::on_board("board-0") });

    wait_output(&mut app, "T2", "UP");
    let restore = app.switch_to("board-1");
    assert_eq!(last_cwd(&restore, "T").as_deref(), Some("/seeded"));
}

// S22
#[test]
fn a_background_board_records_in_its_own_table() {
    let daemon = TestDaemon::start_seeded(&seeded_on_board_1());
    let a = canon_dir(&daemon.dir.join("a"));
    let mut app = daemon.connect_app_drained();

    spawn(&mut app, "N", &plain("read _"), Spawn { cwd: Some(a.clone()), ..Spawn::on_board("board-1") });

    let deadline = Instant::now() + LONG;
    while last_cwd(&app.switch_to("board-1"), "N").as_deref() != Some(a.as_str()) {
        assert!(Instant::now() < deadline, "board-1 never recorded N");
        app.switch_to("board-0");
        std::thread::sleep(Duration::from_millis(100));
    }
    let restore = app.switch_to("board-0");
    assert!(!restore.term_records.contains_key("N"), "{:?}", restore.term_records);
}
