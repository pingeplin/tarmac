// End-to-end daemon basics: a real daemon process on a temp socket, app + cli
// clients speaking the wire protocol over std unix sockets.

mod common;

use std::process::Stdio;
use std::time::{Duration, Instant};

use common::{
    Conn, LONG, Spawn, TestDaemon, append_to, contains, settle, signal_and_wait, spawn_daemon, temp_dir,
    wait_for_socket,
};
use tarmac_protocol::{Channel, Msg, channel_dir};

#[test]
fn m0_end_to_end() {
    let daemon = TestDaemon::start();

    // --- app connect: hello_ok then restore (empty registry) ---
    let mut app = daemon.connect_app();
    let docs = app.recv_restore().docs;
    assert!(docs.is_empty(), "fresh daemon should restore zero docs, got {docs:?}");

    // --- spawn a term, expect output then exit 0 ---
    app.spawn_term("t1", &["/bin/echo", "tarmac-test-ok"]);
    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    loop {
        match app.recv(deadline, "echo output") {
            Msg::Output { term_id, bytes } if term_id == "t1" => {
                collected.extend_from_slice(&bytes);
                if contains(&collected, b"tarmac-test-ok") {
                    break;
                }
            }
            Msg::Exit { .. } => {
                panic!("exit before expected output; collected: {:?}", String::from_utf8_lossy(&collected))
            }
            _ => {}
        }
    }
    let (term_id, code) = app.recv_exit();
    assert_eq!(term_id, "t1");
    assert_eq!(code, Some(0));

    // --- cli open: ack + doc_opened pushed to the app ---
    let md_path = daemon.dir.join("note.md");
    std::fs::write(&md_path, "# tarmac\n").unwrap();
    let canon = std::fs::canonicalize(&md_path).unwrap();
    let canon_str = canon.to_string_lossy().into_owned();

    let mut cli = Conn::hello(&daemon.sock, "cli");
    cli.send(&Msg::Open { path: canon_str.clone(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "ack");
    assert!(matches!(reply, Msg::Ack), "expected ack, got {reply:?}");
    drop(cli);

    let entry = app.recv_doc_opened();
    assert_eq!(entry.path, canon_str);
    assert_eq!(entry.via, "cli");

    // --- append to the file: file_event with mtime arrives ---
    settle();
    append_to(&canon, b"\nmore\n");

    let event = app.recv_until("file_event", |m| matches!(m, Msg::FileEvent { .. }));
    let Msg::FileEvent { path, mtime_ms } = event else { unreachable!() };
    assert_eq!(path, canon_str);
    assert!(mtime_ms > 0);

    // --- a second app connection replaces the first and restores the doc ---
    let mut app2 = daemon.connect_app();
    let docs = app2.recv_restore().docs;
    assert_eq!(docs.len(), 1);
    assert_eq!(docs[0].path, canon_str);
    assert_eq!(docs[0].via, "cli");
    assert!(docs[0].last_changed_ms.is_some());
}

// The handshake reply carries the daemon's build version and OS pid, so the app
// can detect a post-upgrade mismatch and SIGTERM the running daemon by pid.
// A daemon that sent None for either field would fail this.
#[test]
fn hello_ok_reports_daemon_version_and_pid() {
    let daemon = TestDaemon::start();
    let mut app = Conn::connect(&daemon.sock);
    app.send(&Msg::Hello { role: "app".into(), v: tarmac_protocol::PROTOCOL_VERSION, app_version: None });
    let reply = app.recv(Instant::now() + LONG, "hello_ok");
    let Msg::HelloOk { v, daemon_version, daemon_pid, .. } = reply else {
        panic!("expected hello_ok, got {reply:?}");
    };
    assert_eq!(v, tarmac_protocol::PROTOCOL_VERSION);
    assert_eq!(daemon_version.as_deref(), Some(env!("CARGO_PKG_VERSION")));
    assert_eq!(daemon_pid, Some(daemon.child.id()));
}

#[test]
fn term_input_pty_size_and_exit_code() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.spawn_term_with(
        "t2",
        &["/bin/sh", "-c", "stty size; read line; echo got-$line; exit 7"],
        Spawn { cols: 100, rows: 30, cwd: Some(daemon.dir.to_string_lossy().into_owned()), ..Default::default() },
    );

    let mut collected = Vec::new();
    app.collect_output_into(&mut collected, "t2", "stty size output", b"30 100");

    app.input("t2", b"ping\n");
    app.collect_output_into(&mut collected, "t2", "echoed input", b"got-ping");

    let (term_id, code) = app.recv_exit();
    assert_eq!(term_id, "t2");
    assert_eq!(code, Some(7));
}

#[test]
fn open_errors_for_missing_or_relative_paths() {
    let daemon = TestDaemon::start();
    let mut cli = Conn::hello(&daemon.sock, "cli");

    cli.send(&Msg::Open {
        path: daemon.dir.join("nope.md").to_string_lossy().into_owned(),
        term_id: None,
        board_id: None,
    });
    let reply = cli.recv(Instant::now() + LONG, "err for missing file");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");

    cli.send(&Msg::Open { path: "relative.md".into(), term_id: None, board_id: None });
    let reply = cli.recv(Instant::now() + LONG, "err for relative path");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");
}

#[test]
fn bad_role_is_rejected() {
    let daemon = TestDaemon::start();
    let mut conn = Conn::connect(&daemon.sock);
    conn.send(&Msg::Hello { role: "gremlin".into(), v: 1, app_version: None });
    let reply = conn.recv(Instant::now() + LONG, "err for bad role");
    assert!(matches!(reply, Msg::Err { .. }), "expected err, got {reply:?}");
}

#[test]
fn socket_claiming() {
    let dir = temp_dir();
    let sock = dir.join("tarmacd.sock");

    let mut first = spawn_daemon(&sock);
    wait_for_socket(&sock);

    // Second daemon against a live socket exits 1.
    let mut second = spawn_daemon(&sock);
    let deadline = Instant::now() + LONG;
    let status = loop {
        if let Some(status) = second.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "second daemon did not exit");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(status.code(), Some(1));
    // The loser exiting must not disturb the winner: it still serves.
    let _ = Conn::hello(&sock, "cli");

    // SIGKILL the live daemon: the socket file goes stale on disk.
    first.kill().unwrap();
    first.wait().unwrap();
    assert!(sock.exists(), "socket file should remain after SIGKILL");

    // A new daemon must unlink the stale socket and bind.
    let mut third = spawn_daemon(&sock);
    wait_for_socket(&sock);
    let _ = Conn::hello(&sock, "cli");

    let _ = third.kill();
    let _ = third.wait();
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn sighup_shuts_down_cleanly() {
    let mut daemon = TestDaemon::start();

    let status = signal_and_wait(&mut daemon.child, libc::SIGHUP);

    assert!(
        status.code() == Some(0) && !daemon.sock.exists(),
        "SIGHUP must unlink the socket and exit 0; got status={status:?} socket_exists={}",
        daemon.sock.exists()
    );
}

// ── app-version relay (spec 2609.0012) ───────────────────────────────────────
//
// `tarmac --version` reports the *running* app's version, which reaches the CLI
// only through the daemon's app slot. `app_connected` and `app_version` are
// deliberately independent: an app that reports no version is still an observed
// app, and must never render as "no app".
//
// Timing note: the daemon writes `hello_ok` BEFORE `install_app` fills the slot,
// so an app's own reply is not proof the slot is populated. `connect_app_drained_as`
// waits for board_list+restore, which are sent after the install — that is the
// signal these tests synchronise on.

#[test]
fn cli_hello_ok_reports_the_connected_apps_version() {
    let daemon = TestDaemon::start();
    let _app = daemon.connect_app_drained_as(Some("9.9.9"));

    let (connected, version) = Conn::probe_app_slot(&daemon.sock);
    assert_eq!(connected, Some(true));
    assert_eq!(version.as_deref(), Some("9.9.9"));
}

#[test]
fn cli_hello_ok_reports_an_absent_app_as_observed_absence() {
    let daemon = TestDaemon::start();

    let (connected, version) = Conn::probe_app_slot(&daemon.sock);
    assert_eq!(connected, Some(false), "an empty slot is a fact, not an unset key");
    assert_eq!(version, None);
}

#[test]
fn cli_hello_ok_separates_app_presence_from_app_version() {
    let daemon = TestDaemon::start();
    // A pre-key app: connected, but naming no version.
    let _app = daemon.connect_app_drained_as(None);

    let (connected, version) = Conn::probe_app_slot(&daemon.sock);
    assert_eq!(connected, Some(true), "a version-less app is still a connected app");
    assert_eq!(version, None);
}

#[test]
fn a_disconnected_app_is_never_reported_as_connected() {
    let daemon = TestDaemon::start();
    let app = daemon.connect_app_drained_as(Some("9.9.9"));
    assert_eq!(Conn::probe_app_slot(&daemon.sock).0, Some(true));

    drop(app);
    // remove_app runs only once the daemon observes the EOF, so poll rather than
    // race it.
    let deadline = Instant::now() + LONG;
    loop {
        let (connected, version) = Conn::probe_app_slot(&daemon.sock);
        if connected == Some(false) {
            assert_eq!(version, None, "a dead app must not leave its version behind");
            return;
        }
        assert!(Instant::now() < deadline, "app slot never cleared after disconnect");
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn a_cli_hello_never_fills_the_app_slot() {
    let daemon = TestDaemon::start();
    // A cli client that (wrongly) names a version must not be mistaken for an app.
    let (_held, _) = Conn::hello_as(&daemon.sock, "cli", Some("6.6.6"));

    let (connected, version) = Conn::probe_app_slot(&daemon.sock);
    assert_eq!(connected, Some(false));
    assert_eq!(version, None);
}

#[test]
fn the_daemon_makes_no_app_claim_to_an_app() {
    let daemon = TestDaemon::start();
    let _first = daemon.connect_app_drained_as(Some("9.9.9"));

    // The second app's own hello_ok must carry neither key: `false` would be an
    // observably wrong claim while the first app still holds the slot. The reply
    // is built before install_app runs, so an arm that read the slot would report
    // app 1 here — which is what makes the two-app form the one that can fail.
    let (_second, reply) = Conn::hello_as(&daemon.sock, "app", Some("7.7.7"));
    let Msg::HelloOk { app_version, app_connected, .. } = reply else { panic!("expected hello_ok, got {reply:?}") };
    assert_eq!(app_version, None);
    assert_eq!(app_connected, None);
}

#[test]
fn cli_hello_ok_reports_daemon_version_and_pid_alongside_the_app() {
    let daemon = TestDaemon::start();
    let _app = daemon.connect_app_drained_as(Some("9.9.9"));

    let (_cli, reply) = Conn::hello_as(&daemon.sock, "cli", None);
    let Msg::HelloOk { daemon_version, daemon_pid, app_version, .. } = reply else {
        panic!("expected hello_ok, got {reply:?}")
    };
    assert_eq!(daemon_version.as_deref(), Some(env!("CARGO_PKG_VERSION")));
    assert_eq!(daemon_pid, Some(daemon.child.id()));
    assert_eq!(app_version.as_deref(), Some("9.9.9"));
}

/// The hard `RLIMIT_NOFILE` of the test process, which a daemon it starts inherits.
fn hard_file_limit() -> libc::rlim_t {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: `limit` is a valid rlimit for getrlimit to fill.
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) }, 0);
    limit.rlim_max
}

/// The daemon starts at launchd's soft limit of 256 files, under `hard`.
fn starts_at_256_files(cmd: &mut std::process::Command, hard: libc::rlim_t) {
    use std::os::unix::process::CommandExt;
    // SAFETY: setrlimit is async-signal-safe, and nothing else runs here.
    unsafe {
        cmd.pre_exec(move || {
            let launchd = libc::rlimit { rlim_cur: 256, rlim_max: hard };
            match libc::setrlimit(libc::RLIMIT_NOFILE, &launchd) {
                0 => Ok(()),
                _ => Err(std::io::Error::last_os_error()),
            }
        });
    }
}

#[test]
fn a_daemon_started_at_256_files_gives_its_shells_open_max_and_keeps_the_hard_limit() {
    let hard = hard_file_limit();
    let mut per_proc: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the name is NUL-terminated and `per_proc` is `size` bytes.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.maxfilesperproc".as_ptr(),
            (&raw mut per_proc).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    assert_eq!(rc, 0);
    let daemon = TestDaemon::start_with(|cmd| starts_at_256_files(cmd, hard));
    let mut app = daemon.connect_app();
    app.recv_restore();

    app.spawn_term("t1", &["/bin/sh", "-c", "echo nofile=$(ulimit -n)/$(ulimit -Hn)."]);

    let soft = 10240.min(hard).min(u64::try_from(per_proc).unwrap());
    let hard = if hard == libc::RLIM_INFINITY { "unlimited".to_string() } else { hard.to_string() };
    app.recv_output_containing("t1", &format!("nofile={soft}/{hard}."));
}

// At the daemon's default filter, `info`.
#[test]
fn a_daemon_started_at_256_files_logs_that_it_raised_the_limit() {
    let hard = hard_file_limit();
    let mut daemon = TestDaemon::start_with(|cmd| {
        starts_at_256_files(cmd, hard);
        cmd.env("RUST_LOG", "info").stderr(Stdio::piped());
    });

    let log = daemon.kill_and_read_stderr();

    assert!(log.contains("open file limit raised from 256 to"), "{log}");
}

// With no `TARMAC_STATE`, the state file is in the channel's directory under
// `HOME` (docs/protocol.md), whatever the daemon's working directory is.
#[test]
fn with_no_state_path_given_the_state_is_saved_under_home() {
    let mut home = None;
    let mut daemon = TestDaemon::start_with_dir(|cmd, dir| {
        let (at, cwd) = (dir.join("home"), dir.join("cwd"));
        std::fs::create_dir_all(&at).unwrap();
        std::fs::create_dir_all(&cwd).unwrap();
        cmd.env_remove("TARMAC_STATE").env("HOME", &at).current_dir(cwd);
        home = Some(at);
    });
    let home = home.unwrap();

    let status = signal_and_wait(&mut daemon.child, libc::SIGTERM);

    assert_eq!(status.code(), Some(0));
    let saved = [Channel::Dev, Channel::Release].map(|c| channel_dir(&home, c).join("state.json"));
    assert!(saved.iter().any(|path| path.is_file()), "no state file in {saved:?}");
}

#[test]
fn a_resize_reaches_the_terminal() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    app.spawn_term_with(
        "t1",
        &["/bin/sh", "-c", "read line; stty size"],
        Spawn { cols: 80, rows: 24, cwd: Some(daemon.dir.to_string_lossy().into_owned()), ..Default::default() },
    );

    app.send(&Msg::Resize { term_id: "t1".into(), cols: 100, rows: 30 });
    app.input("t1", b"\n");

    let mut output = Vec::new();
    loop {
        match app.recv(Instant::now() + LONG, "the size and the exit") {
            Msg::Output { term_id, bytes } if term_id == "t1" => output.extend_from_slice(&bytes),
            Msg::Exit { term_id, .. } if term_id == "t1" => break,
            _ => {}
        }
    }
    assert!(contains(&output, b"30 100"), "{}", String::from_utf8_lossy(&output));
}

#[test]
fn a_spawn_with_an_empty_cmd_is_refused() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.spawn_term("t1", &[]);

    let reply = app.recv_until("err", |m| matches!(m, Msg::Err { .. }));
    assert!(matches!(&reply, Msg::Err { msg } if msg == "cmd must be a non-empty argv"), "{reply:?}");
}

/// A launch whose daemon never binds the socket the harness waits on panics,
/// and the panic stops the daemon: no daemon is left with no parent.
#[test]
fn a_launch_that_never_sees_its_socket_stops_its_daemon() {
    let dir = temp_dir();
    let elsewhere = dir.join("elsewhere.sock");
    let to = elsewhere.clone();

    let launched = std::panic::catch_unwind(|| {
        TestDaemon::start_with(move |cmd| {
            cmd.env("TARMAC_SOCKET", &to);
        })
    });

    assert!(launched.is_err(), "the harness saw a socket it was not given");
    assert!(elsewhere.exists(), "the daemon never bound the socket it was given");
    let survivor = std::os::unix::net::UnixStream::connect(&elsewhere).is_ok();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!survivor, "the daemon still listens on {}", elsewhere.display());
}
