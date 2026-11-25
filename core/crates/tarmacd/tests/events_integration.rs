// Spec 2611.0012: the daemon's facts for scripts. The test process is the
// subscriber, on a `cli` connection; the app connection drives the terminals.

mod common;

use std::time::{Duration, Instant};

use common::{
    Conn, FORK_NAME, FrameLog, LONG, Spawn, TestDaemon, canon_dir, cli_open, cli_terms, edit, is_bell_for,
    is_exec_proc_for, is_exit_for, is_file_event_for, is_term_proc_for, none_within, settle, subscriber, temp_dir,
    write_doc,
};
use tarmac_protocol::{Msg, frame};

/// A shell that waits: a typed newline ends it with code 3.
const WAITS: &[&str] = &["/bin/zsh", "-f", "-c", "read _; exit 3"];
const READS: &[&str] = &["/bin/zsh", "-f", "-c", "read _"];
const RINGS: &[&str] = &["/bin/zsh", "-f", "-c", "read _; printf '\\a'; read _"];

/// `cmd` spawned as `term_id`, once its process runs: its first `term_proc`.
fn spawned(app: &mut Conn, term_id: &str, cmd: &[&str], opts: Spawn) {
    app.spawn_term_with(term_id, cmd, opts);
    app.recv_until(&format!("the term_proc of {term_id}"), |m| is_term_proc_for(m, term_id));
}

/// `cmd` spawned as `term_id` and ended; the app has read its `exit`.
fn exited(app: &mut Conn, term_id: &str, cmd: &[&str]) -> Msg {
    app.spawn_term(term_id, cmd);
    app.recv_until(&format!("the exit of {term_id}"), |m| is_exit_for(m, term_id))
}

fn next(sub: &mut Conn, what: &str) -> Msg {
    sub.recv(Instant::now() + LONG, what)
}

fn term_report_kind(msg: &Msg) -> (String, Option<String>, Option<String>) {
    let Msg::TermReport { term_id, kind, text, .. } = msg.clone() else { panic!("not a term_report: {msg:?}") };
    (term_id, kind, text)
}

fn exit_of(msg: &Msg) -> (String, Option<i64>) {
    let Msg::Exit { term_id, code, .. } = msg.clone() else { panic!("not an exit: {msg:?}") };
    (term_id, code)
}

// "Subscriber gets the exit of a live terminal"
#[test]
fn a_subscriber_gets_the_exit_of_a_live_terminal() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    spawned(&mut app, "T", WAITS, Spawn::default());

    let (mut sub, snapshot) = subscriber(&daemon.sock, Some(&["exit"]), Some("T"));
    app.type_line("T", "");

    let got = next(&mut sub, "the exit of T");
    let app_got = app.recv_until("the app's exit of T", |m| is_exit_for(m, "T"));
    assert_eq!(snapshot, vec![]);
    assert_eq!(exit_of(&got), ("T".into(), Some(3)));
    assert_eq!(got, app_got);
}

// "Subscriber gets an exit that already happened"
#[test]
fn an_exit_that_already_happened_is_the_snapshot() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    exited(&mut app, "T", &["/bin/zsh", "-f", "-c", "exit 3"]);
    exited(&mut app, "U", &["/bin/zsh", "-f", "-c", "kill -9 $$"]);

    let (_, t) = subscriber(&daemon.sock, Some(&["exit"]), Some("T"));
    let (_, u) = subscriber(&daemon.sock, Some(&["exit"]), Some("U"));

    assert_eq!(t, vec![Msg::Exit { term_id: "T".into(), code: Some(3), board_id: None }]);
    assert_eq!(u, vec![Msg::Exit { term_id: "U".into(), code: None, board_id: None }]);
}

// "Bell subscriber sees only its terminal"
#[test]
fn a_terminal_filter_passes_that_terminals_bell_only() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    spawned(&mut app, "T", RINGS, Spawn::default());
    spawned(&mut app, "U", RINGS, Spawn::default());

    let (mut sub, snapshot) = subscriber(&daemon.sock, Some(&["bell"]), Some("T"));
    app.type_line("U", "");
    std::thread::sleep(Duration::from_secs(1));
    app.type_line("T", "");

    assert_eq!(snapshot, vec![]);
    assert!(is_bell_for(&next(&mut sub, "the bell of T"), "T"));
    assert!(none_within(&mut sub, Duration::from_secs(1), |_| true));
}

// "Report subscriber gets snapshot then live changes"
#[test]
fn a_report_is_the_snapshot_then_its_changes_come_live() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    spawned(&mut app, "T", READS, Spawn::default());
    spawned(&mut app, "U", READS, Spawn::default());
    assert_eq!(Conn::cli_report(&daemon.sock, "T", "blocked", Some("ok?")), Msg::Ack);

    let (mut sub, snapshot) = subscriber(&daemon.sock, Some(&["report"]), Some("T"));
    let (_, none) = subscriber(&daemon.sock, Some(&["report"]), Some("U"));
    assert_eq!(Conn::cli_report(&daemon.sock, "T", "clear", None), Msg::Ack);

    assert_eq!(
        snapshot.iter().map(term_report_kind).collect::<Vec<_>>(),
        [("T".into(), Some("blocked".into()), Some("ok?".into()))]
    );
    assert_eq!(term_report_kind(&next(&mut sub, "the clear of T")), ("T".into(), None, None));
    assert_eq!(none.iter().map(term_report_kind).collect::<Vec<_>>(), [("U".into(), None, None)]);
}

// "Unfiltered subscriber gets only the doc change"
#[test]
fn a_doc_change_comes_and_no_frame_that_is_not_an_event() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&temp_dir().join("a.md"), "a");
    cli_open(&daemon.sock, &doc);
    app.recv_doc_opened_for(&doc);
    app.spawn_term("T", &["/bin/zsh", "-f", "-c", "while :; do echo x; sleep 0.1; done"]);
    app.recv_output_containing("T", "x");
    settle();

    let (mut sub, _) = subscriber(&daemon.sock, None, None);
    let mtime = edit(&doc);

    let app_mtime = app.recv_file_event_since(&doc, mtime);
    let got = sub.recv_until(
        "the file_event of the doc",
        |m| matches!(m, Msg::FileEvent { path, mtime_ms } if *path == doc && *mtime_ms >= mtime),
    );
    assert_eq!(got, Msg::FileEvent { path: doc.clone(), mtime_ms: app_mtime });
    let not_an_event =
        |m: &Msg| matches!(m, Msg::Output { .. } | Msg::TermProc { .. } | Msg::DocOpened(_) | Msg::BoardList { .. });
    assert!(none_within(&mut sub, Duration::from_secs(2), not_an_event));
}

// "Background board change comes when shown"
#[test]
fn a_background_boards_change_comes_when_it_is_shown() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&temp_dir().join("bg.md"), "a");
    app.create_board("board-1");
    app.open_on("board-1", &doc);
    app.switch_to("board-0");
    settle();

    let (mut sub, _) = subscriber(&daemon.sock, Some(&["changed"]), None);
    edit(&doc);

    assert!(none_within(&mut sub, Duration::from_millis(1500), |_| true));
    app.send(&Msg::BoardSwitch { board_id: "board-1".into() });
    assert!(is_file_event_for(&next(&mut sub, "the change at the switch"), &doc));
}

// "Facts reach subscribers with no app"
#[test]
fn facts_come_with_no_app() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    spawned(&mut app, "T", &["/bin/zsh", "-f", "-c", "sleep 3; printf '\\a'; sleep 1; exit 3"], Spawn::default());
    drop(app);

    let (mut sub, _) = subscriber(&daemon.sock, None, Some("T"));

    assert!(is_bell_for(&next(&mut sub, "the bell of T"), "T"));
    assert_eq!(exit_of(&next(&mut sub, "the exit of T")), ("T".into(), Some(3)));
}

// "Terms list shows live terminals in board order": ids in the other order than the boards, so a sort by id alone fails.
#[test]
fn terms_lists_the_live_terminals_in_board_order() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let (a, b) = (temp_dir(), temp_dir());
    app.create_board("board-1");
    let mut log = FrameLog(Vec::new());
    app.spawn_term_with("t2", READS, Spawn { cwd: Some(a.to_string_lossy().into()), ..Spawn::on_board("board-0") });
    app.spawn_term_with("t1", READS, Spawn { cwd: Some(b.to_string_lossy().into()), ..Spawn::on_board("board-1") });
    // The first term_proc can name the fork before its exec; the row shows the shell's.
    for term_id in ["t2", "t1"] {
        if log.last_proc_name(term_id).is_none_or(|name| name == FORK_NAME) {
            app.log_until(&mut log, &format!("the shell's term_proc of {term_id}"), |m| is_exec_proc_for(m, term_id));
        }
    }
    exited(&mut app, "t0", &["/bin/zsh", "-f", "-c", "exit 0"]);

    let rows = cli_terms(&daemon.sock);

    let got: Vec<_> =
        rows.iter().map(|r| (r.term_id.as_str(), r.board_id.as_str(), r.cwd.clone(), r.proc.clone())).collect();
    assert_eq!(
        got,
        [
            ("t2", "board-0", Some(canon_dir(&a)), log.last_proc_name("t2")),
            ("t1", "board-1", Some(canon_dir(&b)), log.last_proc_name("t1")),
        ]
    );
    assert!(rows.iter().all(|r| r.proc.is_some()));
}

// "Live terminal wins over the exit ring"
#[test]
fn a_live_terminal_wins_over_an_exit_of_the_same_id() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    exited(&mut app, "T", &["/bin/zsh", "-f", "-c", "exit 3"]);
    spawned(&mut app, "T", &["/bin/zsh", "-f", "-c", "read _; exit 4"], Spawn::default());

    let (mut sub, snapshot) = subscriber(&daemon.sock, Some(&["exit"]), Some("T"));
    app.type_line("T", "");

    assert_eq!(snapshot, vec![]);
    assert_eq!(exit_of(&next(&mut sub, "the new T's exit")), ("T".into(), Some(4)));
}

// "Subscribers leave the app slot untouched"
#[test]
fn a_subscriber_is_not_the_app() {
    let daemon = TestDaemon::start();
    let mut a = daemon.connect_app_drained();
    let (mut sub, _) = subscriber(&daemon.sock, Some(&["bell", "exit"]), None);

    assert_eq!(Conn::probe_app_slot(&daemon.sock).0, Some(true));
    spawned(&mut a, "T", &["/bin/zsh", "-f", "-c", "read _; printf '\\a'; sleep 0.5; exit 0"], Spawn::default());
    a.type_line("T", "");
    a.recv_until("the bell of T", |m| is_bell_for(m, "T"));
    a.recv_until("the exit of T", |m| is_exit_for(m, "T"));

    drop(a);
    let deadline = Instant::now() + LONG;
    while Conn::probe_app_slot(&daemon.sock).0 != Some(false) {
        assert!(Instant::now() < deadline, "the app slot never emptied");
        std::thread::sleep(Duration::from_millis(25));
    }
    let mut b = daemon.connect_app_drained();
    spawned(&mut b, "U", RINGS, Spawn::default());
    b.type_line("U", "");

    sub.recv_until("U's bell, after T's frames", |m| is_bell_for(m, "U"));
}

// "Term filter drops doc changes"
#[test]
fn a_terminal_filter_drops_doc_changes() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let doc = write_doc(&temp_dir().join("a.md"), "a");
    cli_open(&daemon.sock, &doc);
    app.recv_doc_opened_for(&doc);
    spawned(&mut app, "T", RINGS, Spawn::default());
    settle();

    let (mut sub, _) = subscriber(&daemon.sock, None, Some("T"));
    let mtime = edit(&doc);
    app.recv_file_event_since(&doc, mtime);
    app.type_line("T", "");

    let first = sub.recv_until("the bell of T", |m| is_bell_for(m, "T") || matches!(m, Msg::FileEvent { .. }));
    assert!(is_bell_for(&first, "T"), "{first:?}");
}

// "Unknown terminal or kind is refused"
#[test]
fn an_unknown_terminal_or_no_known_kind_is_refused_and_closed() {
    let daemon = TestDaemon::start();

    for (kinds, term_id, want) in
        [(None, Some("nope"), "unknown terminal: nope"), (Some(vec!["later".to_string()]), None, "no known event kind")]
    {
        let mut cli = Conn::hello(&daemon.sock, "cli");
        cli.send(&Msg::Subscribe { kinds, term_id: term_id.map(str::to_string) });

        assert_eq!(next(&mut cli, "the refusal"), Msg::Err { msg: want.into() });
        assert_eq!(frame::read_sync(&mut cli.0).unwrap_err().kind(), std::io::ErrorKind::UnexpectedEof);
    }
}

// "Report replay to the app is not published": the report replays of a restore, of the shown board and of every
// other board on a connection's first restore, are not published.
#[test]
fn the_report_replays_are_not_published() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    spawned(&mut app, "T", READS, Spawn::default());
    app.create_board("board-1");
    spawned(&mut app, "W", READS, Spawn::on_board("board-1"));
    app.switch_to("board-0");
    for term_id in ["T", "W"] {
        assert_eq!(Conn::cli_report(&daemon.sock, term_id, "blocked", None), Msg::Ack);
    }
    let (mut sub, _) = subscriber(&daemon.sock, Some(&["report"]), None);
    drop(app);

    let mut app = daemon.connect_app();
    app.recv_report_for("T");
    app.recv_report_for("W");
    assert!(none_within(&mut sub, Duration::from_secs(1), |_| true));

    app.send(&Msg::BoardSwitch { board_id: "board-0".into() });
    app.recv_restore_for("board-0");
    app.recv_report_for("T");
    assert!(none_within(&mut sub, Duration::from_secs(1), |_| true));
}
