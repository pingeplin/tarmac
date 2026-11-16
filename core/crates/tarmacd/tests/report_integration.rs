// Spec 2611.0009: a terminal's report, its holder, its lifetime and its
// frames. A report sent by the test process itself is unattributed (its walk
// never reaches a pty), so it falls back to the foreground leader. A report
// from inside a pty is sent by `nc` (`TestDaemon::nc_reporter`).

mod common;

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use common::{
    ACK, Conn, FrameLog, JOB_SHELL, Spawn, TestDaemon, assert_ack, canon_dir, is_report_for, none_within, probe_until_cwd,
};
use tarmac_protocol::{self as proto, Msg, Tile};

#[derive(Debug, PartialEq)]
struct Seen {
    kind: Option<String>,
    text: Option<String>,
    at_ms: Option<u64>,
    proc: Option<String>,
    read: bool,
}

fn seen(msg: &Msg) -> Seen {
    let Msg::TermReport { kind, text, at_ms, proc, read, .. } = msg.clone() else { panic!("not a term_report: {msg:?}") };
    Seen { kind, text, at_ms, proc, read }
}

fn is_removal_for(msg: &Msg, term_id: &str) -> bool {
    matches!(msg, Msg::TermReport { term_id: t, kind: None, .. } if t == term_id)
}

fn report(term_id: &str, kind: &str, text: Option<&str>) -> Msg {
    Msg::Report { term_id: term_id.into(), kind: kind.into(), text: text.map(str::to_string) }
}

fn hello_cli() -> Msg {
    Msg::Hello { role: "cli".into(), v: proto::PROTOCOL_VERSION, app_version: None }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

#[track_caller]
fn assert_err(answer: Msg, want: &str) {
    assert_eq!(answer, Msg::Err { msg: want.into() });
}

/// A drained app connection with a job shell for each of `term_ids` at its
/// prompt. One at a time: a wait for one terminal's prompt drops the frames
/// of every other.
fn job_shell(daemon: &TestDaemon, term_ids: &[&str]) -> Conn {
    let mut app = daemon.connect_app_drained();
    for t in term_ids {
        app.spawn_term(t, JOB_SHELL);
        app.recv_output_containing(t, "%");
    }
    app
}

/// A report from the test process, its `ack`, and the frame the app got.
fn report_from_test(daemon: &TestDaemon, app: &mut Conn, term_id: &str, kind: &str, text: Option<&str>) -> Seen {
    assert_ack(Conn::cli_report(&daemon.sock, term_id, kind, text));
    seen(&app.recv_report_for(term_id))
}

/// A shell spawn `T` at its prompt, and its shell's process name, read after
/// the prompt shows and one more poll.
fn login_shell(daemon: &TestDaemon, log: &mut FrameLog) -> (Conn, String) {
    let mut app = daemon.shell_at_prompt("T", Spawn::default(), log);
    app.log_for(log, Duration::from_millis(1000));
    let shell = log.last_proc_name("T").expect("a term_proc for the shell");
    (app, shell)
}

// S1, S2
#[test]
fn s1_s2_the_walk_finds_the_agent_below_the_shell_and_the_report_ends_with_it() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let (mut app, shell) = login_shell(&daemon, &mut log);
    assert_ne!(shell, "zsh", "the fallback must not give the agent's name");

    let reporter = daemon.nc_reporter("r", &[hello_cli(), report("T", "blocked", Some("ok?"))]);
    let start = log.len();
    app.type_line("T", &format!("/bin/zsh -f -c '{reporter}; echo SE\"\"NT; sleep 2' &"));
    let at = app.log_until(&mut log, "the report frame", |m| is_report_for(m, "T"));
    let received_ms = now_ms();
    let acked = app.log_until_output(&mut log, "T", start, ACK);

    let frame = seen(&log.0[at].msg);
    assert_eq!(
        (frame.kind.as_deref(), frame.text.as_deref(), frame.proc.as_deref(), frame.read),
        (Some("blocked"), Some("ok?"), Some("zsh"), false)
    );
    assert!(received_ms.abs_diff(frame.at_ms.unwrap()) < 2000, "at_ms {:?} vs {received_ms}", frame.at_ms);
    assert!(at < acked, "the report frame ({at}) comes before the ack reaches the pty ({acked})");

    let sent = app.log_until_output(&mut log, "T", start, b"SENT");
    let sent_at = log.0[sent].at;
    let removal = app.log_until(&mut log, "the removal", |m| is_removal_for(m, "T") || matches!(m, Msg::Exit { .. }));
    assert!(is_removal_for(&log.0[removal].msg, "T"), "T exited: {:?}", log.0[removal].msg);
    let after = log.0[removal].at - sent_at;
    assert!(after <= Duration::from_millis(3500), "the removal came {after:?} after SENT");
}

// The report's proc is the same lookup as the card title (#349).
#[test]
fn a_report_names_a_symlinked_holder_by_the_link() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.spawn_as_claude("T");
    app.recv_until("term_proc after exec", |m| matches!(m, Msg::TermProc { term_id, name, .. } if term_id == "T" && name != "tarmacd"));

    let frame = report_from_test(&daemon, &mut app, "T", "blocked", None);
    assert_eq!(frame.proc.as_deref(), Some("claude"));
}

// S3
#[test]
fn s3_an_unattributed_report_is_held_by_the_foreground_leader() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    app.type_line("T", "sleep 5");
    let typed = Instant::now();
    app.recv_until("term_proc sleep", |m| matches!(m, Msg::TermProc { term_id, name, .. } if term_id == "T" && name == "sleep"));

    let frame = report_from_test(&daemon, &mut app, "T", "done", None);
    assert_eq!((frame.kind.as_deref(), frame.proc.as_deref(), frame.text), (Some("done"), Some("sleep"), None));

    let removal = app.recv_until("the removal", |m| is_removal_for(m, "T") || matches!(m, Msg::Exit { .. }));
    let after = typed.elapsed();
    assert!(is_removal_for(&removal, "T"), "T exited: {removal:?}");
    assert!(after >= Duration::from_secs(4) && after <= Duration::from_millis(6500), "removed {after:?} after sleep 5");
}

// S4
#[test]
fn s4_a_child_spawned_as_cmd_is_the_agent() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let reporter = daemon.nc_reporter("r", &[hello_cli(), report("T", "blocked", None)]);
    let script = format!("/bin/sh -c '{reporter}; echo MID'; echo SE\"\"NT; read _");
    let mut log = FrameLog::default();
    app.spawn_term("T", &["/bin/zsh", "-f", "-c", &script]);

    let at = app.log_until(&mut log, "the report frame", |m| is_report_for(m, "T"));
    let sent = app.log_until_output(&mut log, "T", 0, b"SENT");
    assert!(log.output_index_containing("T", 0, ACK).is_some(), "the reporter got its ack");

    assert_eq!(seen(&log.0[at].msg).proc.as_deref(), Some("zsh"));
    assert!(log.reports_for("T", at + 1).is_empty(), "no removal by {sent}");
    assert!(none_within(&mut app, Duration::from_secs(2), |m| is_report_for(m, "T")));
}

// S5, S27
#[test]
fn s5_s27_only_typed_input_marks_a_report_read() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    let first = report_from_test(&daemon, &mut app, "T", "blocked", Some("ok?"));

    app.input("T", b"\n");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")));
    app.keystroke("T", b"\n");
    let read = seen(&app.recv_report_for("T"));

    assert_eq!(read, Seen { read: true, ..first });
    app.keystroke("T", b"\n");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")));
}

// S13
#[test]
fn s13_a_report_is_not_saved() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    app.send(&Msg::Layout {
        dock: vec![],
        tiles: vec![Tile { kind: "term".into(), term_id: Some("T".into()), ..Default::default() }],
        board: None,
        board_id: None,
    });
    daemon.wait_for_state("the layout", |v| v["boards"][0]["tiles"][0]["term_id"] == "T");
    std::thread::sleep(Duration::from_millis(500));
    let kept = std::fs::read(daemon.state_file()).unwrap();

    report_from_test(&daemon, &mut app, "T", "blocked", Some("not-saved-text"));
    std::thread::sleep(Duration::from_secs(1));

    let now = std::fs::read(daemon.state_file()).unwrap();
    assert_eq!(now, kept);
    assert!(!common::contains(&now, b"not-saved-text") && !common::contains(&now, b"report"));
}

// S14
#[test]
fn s14_a_new_app_connection_gets_every_report_after_its_restore() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T", "U"]);
    let first = report_from_test(&daemon, &mut app, "T", "blocked", Some("ok?"));
    app.keystroke("T", b"\n");
    app.recv_until("T read", |m| is_report_for(m, "T") && seen(m).read);
    drop(app);
    std::thread::sleep(Duration::from_millis(300));
    assert_ack(Conn::cli_report(&daemon.sock, "U", "done", None));

    let mut app = daemon.connect_app();
    let mut log = FrameLog::default();
    let restore = app.log_until(&mut log, "restore", |m| matches!(m, Msg::Restore { .. }));
    let t_output = app.log_until_output(&mut log, "T", restore, b"%");
    let u_output = app.log_until_output(&mut log, "U", restore, b"%");

    let t = log.reports_for("T", 0);
    let u = log.reports_for("U", 0);
    assert_eq!(t.len(), 1, "one frame for T");
    assert_eq!(u.len(), 1, "one frame for U");
    assert_eq!(seen(&log.0[t[0]].msg), Seen { read: true, ..first });
    let u_frame = seen(&log.0[u[0]].msg);
    assert_eq!((u_frame.kind.as_deref(), u_frame.read), (Some("done"), false));
    let first_output = (restore..log.len()).find(|&i| matches!(log.0[i].msg, Msg::Output { .. })).unwrap();
    for i in [t[0], u[0]] {
        assert!(restore < i && i < first_output, "report frame {i} between restore {restore} and output {first_output}");
    }
    assert!(first_output <= t_output.min(u_output));
}

// S15
#[test]
fn s15_a_background_boards_reports_come_with_each_of_its_restores() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    app.switch_to("board-0");
    app.spawn_term_with("T", JOB_SHELL, Spawn::on_board("board-1"));
    app.recv_output_containing("T", "%");
    let first = report_from_test(&daemon, &mut app, "T", "blocked", None);

    app.switch_to("board-1");
    let again = app.recv_within(Duration::from_secs(2), |m| is_report_for(m, "T")).expect("a report frame after the restore");
    assert_eq!(seen(&again).at_ms, first.at_ms);

    app.switch_to("board-0");
    app.switch_to("board-1");
    let third = app.recv_within(Duration::from_secs(2), |m| is_report_for(m, "T")).expect("a report frame after the second restore");
    assert_eq!(seen(&third).at_ms, first.at_ms);
}

// S32
#[test]
fn s32_a_report_removed_while_no_app_is_connected_is_removed_at_the_next_restore() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T", "U"]);
    app.type_line("T", "sleep 2");
    let typed = Instant::now();
    app.recv_until("term_proc sleep", |m| matches!(m, Msg::TermProc { term_id, name, .. } if term_id == "T" && name == "sleep"));
    let frame = report_from_test(&daemon, &mut app, "T", "blocked", None);
    assert_eq!(frame.proc.as_deref(), Some("sleep"));
    drop(app);

    // `sleep` ends at 2 s and the next tick sees it by 2.75 s.
    std::thread::sleep(Duration::from_secs(4).saturating_sub(typed.elapsed()));
    let mut app = daemon.connect_app();
    let mut log = FrameLog::default();
    let restore = app.log_until(&mut log, "restore", |m| matches!(m, Msg::Restore { .. }));
    app.log_until_output(&mut log, "T", restore, b"%");
    app.log_until_output(&mut log, "U", restore, b"%");
    for term in ["T", "U"] {
        let frames = log.reports_for(term, restore);
        assert_eq!(frames.len(), 1, "one frame for {term}");
        assert!(is_removal_for(&log.0[frames[0]].msg, term), "{:?}", log.0[frames[0]].msg);
    }
}

// S16
#[test]
fn s16_an_exit_ends_the_report_with_no_frame_and_leaves_no_entry() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.spawn_term("T", &["/bin/sh", "-c", "echo READY; read _; exit 0"]);
    app.recv_output_containing("T", "READY");
    report_from_test(&daemon, &mut app, "T", "done", None);

    app.type_line("T", "");
    let (term, _) = app.recv_exit();
    assert_eq!(term, "T");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")));
    assert_err(Conn::cli_report(&daemon.sock, "T", "done", None), "unknown terminal: T");

    app.spawn_term("T", JOB_SHELL);
    app.recv_output_containing("T", "%");
    let mut app = daemon.connect_app();
    app.recv_restore();
    let frame = app.recv_report_for("T");
    assert!(is_removal_for(&frame, "T"), "the old entry survived the exit: {frame:?}");
}

// S17
#[test]
fn s17_clear_with_no_report_sends_nothing() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    assert_ack(Conn::cli_report(&daemon.sock, "T", "clear", None));
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")));
}

#[test]
fn clear_removes_a_report() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    report_from_test(&daemon, &mut app, "T", "done", None);
    assert_ack(Conn::cli_report(&daemon.sock, "T", "clear", Some("ignored")));
    assert!(is_removal_for(&app.recv_report_for("T"), "T"));
}

// S18
#[test]
fn s18_the_daemon_caps_a_raw_clients_text() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    // Three bytes a char: a cap by bytes would keep 93 chars, or split one.
    let long = "中".repeat(1000);
    let frame = report_from_test(&daemon, &mut app, "T", "blocked", Some(&long));
    assert_eq!(frame.text, Some(format!("{}…", "中".repeat(proto::REPORT_TEXT_MAX - 1))));
}

// S21
#[test]
fn s21_an_identical_repeat_is_a_new_unread_report() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    let first = report_from_test(&daemon, &mut app, "T", "blocked", Some("ok?"));
    app.keystroke("T", b"\n");
    app.recv_until("T read", |m| is_report_for(m, "T") && seen(m).read);
    std::thread::sleep(Duration::from_millis(1100));

    let again = report_from_test(&daemon, &mut app, "T", "blocked", Some("ok?"));
    assert!(again.at_ms > first.at_ms);
    assert!(!again.read);
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")), "one frame");

    app.keystroke("T", b"\n");
    assert!(seen(&app.recv_report_for("T")).read);
}

// S26
#[test]
fn s26_the_daemon_refuses_an_unknown_terminal_or_kind_and_drops_an_empty_text() {
    let daemon = TestDaemon::start();
    let mut app = job_shell(&daemon, &["T"]);
    assert_err(Conn::cli_report(&daemon.sock, "nobody", "done", None), "unknown terminal: nobody");
    assert_err(Conn::cli_report(&daemon.sock, "T", "later", None), "unknown report kind: later");
    assert!(none_within(&mut app, Duration::from_secs(1), |m| is_report_for(m, "T")));

    let frame = report_from_test(&daemon, &mut app, "T", "blocked", Some(""));
    assert_eq!(frame.text, None);
}

// S33
#[test]
fn s33_a_report_typed_at_the_prompt_is_held_by_the_shell() {
    let daemon = TestDaemon::start_sh();
    let mut log = FrameLog::default();
    let (mut app, shell) = login_shell(&daemon, &mut log);

    let reporter = daemon.nc_reporter("r", &[hello_cli(), report("T", "done", None)]);
    let start = log.len();
    app.type_line("T", &format!("{reporter}; echo BA\"\"CK"));
    let at = app.log_until(&mut log, "the report frame", |m| is_report_for(m, "T"));
    app.log_until_output(&mut log, "T", start, b"BACK");
    assert!(log.output_index_containing("T", start, ACK).is_some(), "the reporter got its ack");

    assert_eq!(seen(&log.0[at].msg).proc.as_deref(), Some(shell.as_str()));
    assert!(log.reports_for("T", at + 1).is_empty());
    assert!(none_within(&mut app, Duration::from_secs(2), |m| is_report_for(m, "T")));

    app.type_line("T", "sleep 2");
    let typed = Instant::now();
    let removal = app.recv_until("the removal", |m| is_report_for(m, "T") || matches!(m, Msg::Exit { .. }));
    assert!(is_removal_for(&removal, "T"), "{removal:?}");
    assert!(typed.elapsed() <= Duration::from_millis(1500), "removed {:?} after sleep 2", typed.elapsed());
}


// Spec 2611.0013: the place of a report, the connect replay of other boards'
// reports, and the board of a bell and an exit.

/// A report frame's `board_id` and `cwd`.
fn place(msg: &Msg) -> (Option<String>, Option<String>) {
    let Msg::TermReport { board_id, cwd, .. } = msg.clone() else { panic!("not a term_report: {msg:?}") };
    (board_id, cwd)
}

fn has_kind_for(msg: &Msg, term_id: &str) -> bool {
    matches!(msg, Msg::TermReport { term_id: t, kind: Some(_), .. } if t == term_id)
}

// S11
#[test]
fn s11_a_report_frame_carries_its_board_and_folder_and_a_removal_neither() {
    let daemon = TestDaemon::start();
    let dir = canon_dir(&common::temp_dir().join("api"));
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    app.spawn_term_with("T", JOB_SHELL, Spawn { cwd: Some(dir.clone()), ..Spawn::on_board("board-1") });
    app.recv_output_containing("T", "%");
    let mut app = probe_until_cwd(&daemon, "T", &dir);

    assert_ack(Conn::cli_report(&daemon.sock, "T", "blocked", None));
    let frame = app.recv_until("T's report", |m| has_kind_for(m, "T"));
    assert_eq!(place(&frame), (Some("board-1".into()), Some(dir)));

    assert_ack(Conn::cli_report(&daemon.sock, "T", "clear", None));
    let removal = app.recv_report_for("T");
    assert!(is_removal_for(&removal, "T"), "{removal:?}");
    assert_eq!(place(&removal), (None, None));
}

// S11, with the terminal's board in the background: the place is its own
// board's, not the shown one's.
#[test]
fn s11_a_background_terminals_report_carries_its_own_board_and_folder() {
    let daemon = TestDaemon::start();
    let dir = canon_dir(&common::temp_dir().join("api"));
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    app.spawn_term_with("T", JOB_SHELL, Spawn { cwd: Some(dir.clone()), ..Spawn::on_board("board-1") });
    app.recv_output_containing("T", "%");
    let mut app = probe_until_cwd(&daemon, "T", &dir);
    app.switch_to("board-0");

    assert_ack(Conn::cli_report(&daemon.sock, "T", "blocked", None));
    let frame = app.recv_until("T's report", |m| has_kind_for(m, "T"));
    assert_eq!(place(&frame), (Some("board-1".into()), Some(dir)));
}

/// Board-0 shown with a shell A; board-1 with shells T, in `dir` and its
/// folder recorded, and U, where T has a report the test marked read. The app
/// connection is closed.
fn two_boards_with_a_read_report(daemon: &TestDaemon, dir: &str) -> Seen {
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    app.spawn_term_with("T", JOB_SHELL, Spawn { cwd: Some(dir.into()), ..Spawn::on_board("board-1") });
    app.recv_output_containing("T", "%");
    let mut app = probe_until_cwd(daemon, "T", dir);
    app.spawn_term_with("U", JOB_SHELL, Spawn::on_board("board-1"));
    app.recv_output_containing("U", "%");
    app.switch_to("board-0");
    app.spawn_term_with("A", JOB_SHELL, Spawn::on_board("board-0"));
    app.recv_output_containing("A", "%");
    let first = report_from_test(daemon, &mut app, "T", "blocked", Some("ok?"));
    app.keystroke("T", b"\n");
    app.recv_until("T read", |m| is_report_for(m, "T") && seen(m).read);
    drop(app);
    std::thread::sleep(Duration::from_millis(300));
    first
}

// S12, S13
#[test]
fn s12_s13_a_new_connection_gets_other_boards_reports_once_after_its_first_restore() {
    let daemon = TestDaemon::start();
    let dir = canon_dir(&common::temp_dir().join("api"));
    let first = two_boards_with_a_read_report(&daemon, &dir);

    let mut app = daemon.connect_app();
    let mut log = FrameLog::default();
    let restore = app.log_until(&mut log, "restore", |m| matches!(m, Msg::Restore { .. }));
    app.log_until_output(&mut log, "A", restore, b"%");
    app.log_for(&mut log, Duration::from_millis(500));

    let (a, t) = (log.reports_for("A", 0), log.reports_for("T", 0));
    assert_eq!(a.len(), 1, "one frame for A");
    assert!(is_removal_for(&log.0[a[0]].msg, "A"));
    assert_eq!(t.len(), 1, "one frame for T");
    assert_eq!(seen(&log.0[t[0]].msg), Seen { read: true, ..first });
    assert_eq!(place(&log.0[t[0]].msg), (Some("board-1".into()), Some(dir.clone())));
    assert!(log.reports_for("U", 0).is_empty(), "U has no report and gets no frame");
    let first_output = (restore..log.len()).find(|&i| matches!(log.0[i].msg, Msg::Output { .. })).unwrap();
    for i in [a[0], t[0]] {
        assert!(restore < i && i < first_output, "report frame {i} between restore {restore} and output {first_output}");
    }

    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    let shown = app.log_until(&mut log, "board-1's restore", |m| matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some("board-1")));
    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    let back = app.log_until(&mut log, "board-0's restore", |m| matches!(m, Msg::Restore { board_id, .. } if board_id.as_deref() == Some("board-0")));
    app.log_for(&mut log, Duration::from_millis(500));

    let between = |term: &str| log.reports_for(term, shown).into_iter().filter(|&i| i < back).count();
    assert_eq!((between("T"), between("U"), between("A")), (1, 1, 0), "board-1's restore has its own set");
    assert_eq!(log.reports_for("A", back).len(), 1, "board-0's second restore has A's frame");
    assert!(log.reports_for("T", back).is_empty(), "the replay runs once per connection");
}

// S42
#[test]
fn s42_a_bell_and_an_exit_carry_the_board_of_their_terminal() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    app.switch_to("board-0");
    app.spawn_term_with("T", &["/bin/sh", "-c", "printf 'READY\\a'; read _; exit 3"], Spawn::on_board("board-1"));

    let bell = app.recv_until("T's bell", |m| matches!(m, Msg::Bell { term_id, .. } if term_id == "T"));
    assert_eq!(bell, Msg::Bell { term_id: "T".into(), board_id: Some("board-1".into()) });

    app.type_line("T", "");
    let exit = app.recv_until("T's exit", |m| matches!(m, Msg::Exit { term_id, .. } if term_id == "T"));
    assert_eq!(exit, Msg::Exit { term_id: "T".into(), code: Some(3), board_id: Some("board-1".into()) });
}
