// Spec 2611.0016: `tarmac term new`, with the test as the cli and a fake app.

mod common;

use std::path::Path;
use std::time::{Duration, Instant};

use common::{Conn, LONG, Spawn, TestDaemon, cli_terms};
use tarmac_protocol::Msg;

const QUIET: Duration = Duration::from_millis(500);

/// A cli connection that has sent `term_new`; its answer is still unread.
fn ask(sock: &Path, cmd: &str, cwd: &str, term_id: Option<&str>) -> Conn {
    let mut cli = Conn::hello(sock, "cli");
    cli.send(&Msg::TermNew {
        req_id: None,
        cmd: cmd.into(),
        cwd: cwd.into(),
        term_id: term_id.map(str::to_string),
        board_id: None,
    });
    cli
}

fn answer(cli: &mut Conn) -> Msg {
    cli.recv(Instant::now() + LONG, "the answer to term_new")
}

/// The `term_new` the app gets: `(req_id, the frame)`.
fn forwarded(app: &mut Conn) -> (u64, Msg) {
    let msg = app.recv_until("term_new", |m| matches!(m, Msg::TermNew { .. }));
    let Msg::TermNew { req_id: Some(req_id), .. } = msg else { panic!("a term_new with no req_id: {msg:?}") };
    (req_id, msg)
}

fn none_forwarded(app: &mut Conn) -> bool {
    app.recv_within(QUIET, |m| matches!(m, Msg::TermNew { .. })).is_none()
}

/// A `read`-blocked terminal `term_id`, live once the daemon lists it.
fn live_term(daemon: &TestDaemon, app: &mut Conn, term_id: &str, board_id: Option<&str>) {
    let opts = Spawn { board_id: board_id.map(str::to_string), ..Spawn::default() };
    app.spawn_term_with(term_id, &["/bin/sh", "-c", "read _"], opts);
    let deadline = Instant::now() + LONG;
    while !cli_terms(&daemon.sock).iter().any(|t| t.term_id == term_id) {
        assert!(Instant::now() < deadline, "{term_id} never ran");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// What the app does for a placed card: the spawn, the held command, the answer.
fn place(app: &mut Conn, req_id: u64, term_id: &str, cmd: &str) {
    app.spawn_term_with(term_id, &[], Spawn { cwd: Some("/tmp".into()), board_id: Some("board-0".into()), ..Spawn::login_shell() });
    app.send(&Msg::Input { term_id: term_id.into(), bytes: format!("{cmd}\r").into_bytes(), typed: false, hold: true });
    app.send(&Msg::TermNewOk { req_id: Some(req_id), term_id: term_id.into() });
}

fn ok(term_id: &str) -> Msg {
    Msg::TermNewOk { req_id: None, term_id: term_id.into() }
}

fn err(msg: &str) -> Msg {
    Msg::Err { msg: msg.into() }
}

// S1
#[test]
fn s1_the_app_gets_the_request_with_its_number_and_the_callers_board() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    live_term(&daemon, &mut app, "t1", None);

    let _cli = ask(&daemon.sock, "echo hi", "/tmp", Some("t1"));

    let (req_id, msg) = forwarded(&mut app);
    assert_eq!(msg, Msg::TermNew {
        req_id: Some(req_id),
        cmd: "echo hi".into(),
        cwd: "/tmp".into(),
        term_id: Some("t1".into()),
        board_id: Some("board-0".into()),
    });
}

// S2
#[test]
fn s2_the_cli_gets_the_new_terminal_which_is_live_on_its_board() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    live_term(&daemon, &mut app, "t1", None);
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", Some("t1"));
    let (req_id, _) = forwarded(&mut app);

    place(&mut app, req_id, "t9", "echo hi");

    assert_eq!(answer(&mut cli), ok("t9"));
    let t9 = cli_terms(&daemon.sock).into_iter().find(|t| t.term_id == "t9").expect("t9 is listed");
    assert_eq!(t9.board_id, "board-0");
}

// S3
#[test]
fn s3_a_caller_on_a_background_board_names_that_board() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");
    live_term(&daemon, &mut app, "t1", Some("board-1"));
    app.switch_to("board-0");

    let _cli = ask(&daemon.sock, "echo hi", "/tmp", Some("t1"));

    let (_, msg) = forwarded(&mut app);
    assert!(matches!(msg, Msg::TermNew { board_id: Some(b), .. } if b == "board-1"));
}

// S11
#[test]
fn s11_no_caller_or_one_not_live_is_the_active_board_with_no_owner() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    app.create_board("board-1");

    for caller in [None, Some("t-gone")] {
        let _cli = ask(&daemon.sock, "echo hi", "/tmp", caller);

        let (_, msg) = forwarded(&mut app);
        assert!(
            matches!(&msg, Msg::TermNew { term_id: None, board_id: Some(b), .. } if b == "board-1"),
            "{caller:?}: {msg:?}"
        );
    }
}

// S13
#[test]
fn s13_an_answer_for_a_cli_that_went_away_is_dropped() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (req_id, _) = forwarded(&mut app);
    drop(cli);

    place(&mut app, req_id, "t9", "echo hi");

    let mut again = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (next, _) = forwarded(&mut app);
    app.send(&Msg::TermNewErr { req_id: next, msg: "m".into() });
    assert_eq!(answer(&mut again), err("m"), "the daemon goes on serving");
}

// S16
#[test]
fn s16_with_no_app_the_cli_is_refused_and_nothing_is_spawned() {
    let daemon = TestDaemon::start_sh();

    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);

    assert_eq!(answer(&mut cli), err("no app connected"));
    assert!(cli_terms(&daemon.sock).is_empty());
}

// S17
#[test]
fn s17_an_app_that_goes_away_ends_the_request() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    forwarded(&mut app);

    drop(app);

    assert_eq!(answer(&mut cli), err("the app went away"));
}

// S17
#[test]
fn s17_an_app_that_takes_the_place_of_the_first_ends_its_requests() {
    let daemon = TestDaemon::start_sh();
    let mut first = daemon.connect_app_drained();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    forwarded(&mut first);

    let _second = daemon.connect_app_drained();

    assert_eq!(answer(&mut cli), err("the app went away"));
}

// S18
#[test]
fn s18_the_apps_refusal_is_the_clis_err() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (req_id, _) = forwarded(&mut app);

    app.send(&Msg::TermNewErr { req_id, msg: "m".into() });

    assert_eq!(answer(&mut cli), err("m"));
}

// S19
#[test]
fn s19_the_daemon_refuses_a_command_the_check_refuses_and_forwards_nothing() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();

    for (cmd, cause) in [("echo a\necho b", "a control character"), ("   ", "empty"), (&*"x".repeat(4097), "over 4096 characters")] {
        let mut cli = ask(&daemon.sock, cmd, "/tmp", None);
        assert_eq!(answer(&mut cli), err(&format!("term new command refused: {cause}")));
    }
    assert!(none_forwarded(&mut app));
}

// S20
#[test]
fn s20_a_folder_that_is_not_an_absolute_directory_is_refused_and_forwards_nothing() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let file = daemon.dir.join("a-file");
    std::fs::write(&file, "x").unwrap();
    let missing = daemon.dir.join("missing");

    for path in [file.to_str().unwrap(), missing.to_str().unwrap()] {
        let mut cli = ask(&daemon.sock, "echo hi", path, None);
        assert_eq!(answer(&mut cli), err(&format!("not a directory: {path}")));
    }
    let mut cli = ask(&daemon.sock, "echo hi", "rel/dir", None);
    assert_eq!(answer(&mut cli), err("not an absolute path: rel/dir"));
    assert!(none_forwarded(&mut app));
}

// S24
#[test]
fn s24_two_requests_answered_in_the_reverse_order_each_get_their_own_terminal() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let mut first = ask(&daemon.sock, "echo one", "/tmp", None);
    let (one, _) = forwarded(&mut app);
    let mut second = ask(&daemon.sock, "echo two", "/tmp", None);
    let (two, _) = forwarded(&mut app);
    assert_ne!(one, two);

    place(&mut app, two, "t10", "echo two");
    place(&mut app, one, "t9", "echo one");

    assert_eq!(answer(&mut first), ok("t9"));
    assert_eq!(answer(&mut second), ok("t10"));
}

// S25
#[test]
fn s25_an_answer_with_no_request_is_ignored() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();

    app.send(&Msg::TermNewOk { req_id: Some(99), term_id: "t9".into() });
    app.send(&Msg::TermNewErr { req_id: 99, msg: "m".into() });

    assert!(cli_terms(&daemon.sock).is_empty(), "the daemon goes on serving");
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (req_id, _) = forwarded(&mut app);
    app.send(&Msg::TermNewErr { req_id, msg: "m".into() });
    assert_eq!(answer(&mut cli), err("m"));
}

// S27
#[test]
fn s27_an_answer_for_a_terminal_the_daemon_does_not_hold_is_a_failed_start() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (req_id, _) = forwarded(&mut app);

    app.send(&Msg::TermNewOk { req_id: Some(req_id), term_id: "t9".into() });

    assert_eq!(answer(&mut cli), err("the terminal did not start"));
}

// D9: a terminal that already ended is one the daemon holds, in its exit ring.
#[test]
fn an_answer_for_a_terminal_that_already_ended_is_the_new_terminal() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    let (req_id, _) = forwarded(&mut app);
    app.spawn_term("t9", &["/usr/bin/true"]);
    app.recv_until("t9's exit", |m| matches!(m, Msg::Exit { term_id, .. } if term_id == "t9"));

    app.send(&Msg::TermNewOk { req_id: Some(req_id), term_id: "t9".into() });

    assert_eq!(answer(&mut cli), ok("t9"));
}

// D10 through the socket: the cli session's bound is the daemon's own, inside
// the cli's wait.
#[test]
fn an_app_that_never_answers_is_no_answer_inside_the_clis_wait() {
    let daemon = TestDaemon::start_sh();
    let mut app = daemon.connect_app_drained();
    let started = Instant::now();
    let mut cli = ask(&daemon.sock, "echo hi", "/tmp", None);
    forwarded(&mut app);

    assert_eq!(answer(&mut cli), err("the app did not answer"));
    assert!(started.elapsed() < tarmac_protocol::DAEMON_WAIT, "answered after {:?}", started.elapsed());
}

// The app is checked before the folder, whose read can take the bound.
#[test]
fn with_no_app_a_bad_folder_is_no_app_connected_at_once() {
    let daemon = TestDaemon::start_sh();

    for cwd in ["rel/dir", "/no/such/dir"] {
        let started = Instant::now();
        let mut cli = ask(&daemon.sock, "echo hi", cwd, None);

        assert_eq!(answer(&mut cli), err("no app connected"), "{cwd}");
        assert!(started.elapsed() < Duration::from_secs(1), "{cwd}: answered after {:?}", started.elapsed());
    }
}
