// issue #77: a spawn_term carrying inherit_cwd_from resolves the SOURCE term's
// LIVE cwd (not its spawn cwd) at spawn time. Harness lives in common/.

mod common;

use std::time::Instant;

use common::{Conn, LONG, TestDaemon, contains};
use tarmac_protocol::Msg;

// A new terminal spawned with inherit_cwd_from starts in the source term's
// CURRENT directory, including after the source has `cd`'d away from where it
// was originally spawned — proving this reflects live state, not spawn cwd.
#[test]
fn spawn_term_inherits_source_terms_live_cwd_after_cd() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    let moved_dir = daemon.dir.join("moved");
    std::fs::create_dir_all(&moved_dir).unwrap();
    let moved = std::fs::canonicalize(&moved_dir).unwrap().to_string_lossy().into_owned();

    // The prime term spawns in daemon.dir, blocks for an input line, `cd`s away
    // to `moved` and echoes a marker (only once the cd has actually completed —
    // shell commands run sequentially in one process, no fork/exec in between),
    // then blocks again so it stays alive as the inherit source.
    app.send(&Msg::SpawnTerm {
        term_id: "prime".into(),
        cols: 80,
        rows: 24,
        cwd: Some(daemon.dir.to_string_lossy().into_owned()),
        cmd: Some(vec![
            "/bin/sh".into(),
            "-c".into(),
            format!("read _; cd '{moved}' && echo CWD_MOVED; read _"),
        ]),
        board_id: None,
        inherit_cwd_from: None,
    });
    app.send(&Msg::Input { term_id: "prime".into(), bytes: b"go\n".to_vec() });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    while !contains(&collected, b"CWD_MOVED") {
        if let Msg::Output { term_id, bytes } = app.recv(deadline, "prime cd marker")
            && term_id == "prime"
        {
            collected.extend_from_slice(&bytes);
        }
    }

    // Spawn a second term inheriting prime's cwd; no explicit cwd of its own.
    app.send(&Msg::SpawnTerm {
        term_id: "t2".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "pwd".into()]),
        board_id: None,
        inherit_cwd_from: Some("prime".into()),
    });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    while !contains(&collected, moved.as_bytes()) {
        match app.recv(deadline, "t2 pwd output") {
            Msg::Output { term_id, bytes } if term_id == "t2" => collected.extend_from_slice(&bytes),
            Msg::Exit { term_id, .. } if term_id == "t2" => panic!(
                "t2 exited before its pwd output showed the inherited dir; collected: {:?}",
                String::from_utf8_lossy(&collected)
            ),
            _ => {}
        }
    }
}

// An inherit_cwd_from pointing at an unknown term_id (never spawned, or already
// exited) is not an error: the daemon silently falls back to term::spawn's own
// default cwd, exactly like a spawn_term that never set the hint at all.
#[test]
fn spawn_term_falls_back_when_inherit_source_is_unknown() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    app.send(&Msg::SpawnTerm {
        term_id: "t1".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "pwd".into()]),
        board_id: None,
        inherit_cwd_from: Some("no-such-term".into()),
    });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    loop {
        match app.recv(deadline, "t1 pwd output or exit") {
            Msg::Output { term_id, bytes } if term_id == "t1" => collected.extend_from_slice(&bytes),
            Msg::Exit { term_id, code } if term_id == "t1" => {
                assert_eq!(code, Some(0), "pwd should exit cleanly even with an unresolvable inherit source");
                break;
            }
            _ => {}
        }
    }
    let pwd = String::from_utf8_lossy(&collected);
    assert!(pwd.trim().starts_with('/'), "expected an absolute default cwd, got {pwd:?}");
}

// issue #77 (the WHICH-pid guard): inheritance resolves the source's live cwd
// even while the source shell has a *foreground child* running (e.g. a build,
// vim, less). live_cwd reads the foreground-process-group leader, so whether
// that child shares the shell's group or gets its own, its cwd is the shell's
// post-`cd` directory — a running job must never break inheritance.
#[test]
fn spawn_term_inherits_live_cwd_while_source_runs_a_foreground_child() {
    let daemon = TestDaemon::start();
    let mut app = Conn::hello(&daemon.sock, "app");
    app.recv_until("restore", |m| matches!(m, Msg::Restore { .. }));

    let moved_dir = daemon.dir.join("moved");
    std::fs::create_dir_all(&moved_dir).unwrap();
    let moved = std::fs::canonicalize(&moved_dir).unwrap().to_string_lossy().into_owned();

    // Prime spawns in daemon.dir, `cd`s into `moved`, echoes a marker, then runs
    // `cat` as a foreground child that blocks on stdin — so at inherit time the
    // prime has a live foreground job, not a bare prompt.
    app.send(&Msg::SpawnTerm {
        term_id: "prime".into(),
        cols: 80,
        rows: 24,
        cwd: Some(daemon.dir.to_string_lossy().into_owned()),
        cmd: Some(vec![
            "/bin/sh".into(),
            "-c".into(),
            format!("read _; cd '{moved}' && echo CWD_MOVED; cat"),
        ]),
        board_id: None,
        inherit_cwd_from: None,
    });
    app.send(&Msg::Input { term_id: "prime".into(), bytes: b"go\n".to_vec() });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    while !contains(&collected, b"CWD_MOVED") {
        if let Msg::Output { term_id, bytes } = app.recv(deadline, "prime cd marker")
            && term_id == "prime"
        {
            collected.extend_from_slice(&bytes);
        }
    }

    app.send(&Msg::SpawnTerm {
        term_id: "t2".into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: Some(vec!["/bin/sh".into(), "-c".into(), "pwd".into()]),
        board_id: None,
        inherit_cwd_from: Some("prime".into()),
    });

    let mut collected = Vec::new();
    let deadline = Instant::now() + LONG;
    while !contains(&collected, moved.as_bytes()) {
        match app.recv(deadline, "t2 pwd output") {
            Msg::Output { term_id, bytes } if term_id == "t2" => collected.extend_from_slice(&bytes),
            Msg::Exit { term_id, .. } if term_id == "t2" => panic!(
                "t2 exited before its pwd output showed the inherited dir; collected: {:?}",
                String::from_utf8_lossy(&collected)
            ),
            _ => {}
        }
    }
}
