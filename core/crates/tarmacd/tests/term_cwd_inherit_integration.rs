// issue #77: a spawn_term carrying inherit_cwd_from resolves the SOURCE term's
// LIVE cwd (not its spawn cwd) at spawn time.

mod common;

use std::time::Instant;

use common::{Conn, LONG, Spawn, TestDaemon, contains};
use tarmac_protocol::Msg;

fn create_moved_dir(daemon: &TestDaemon) -> String {
    let moved_dir = daemon.dir.join("moved");
    std::fs::create_dir_all(&moved_dir).unwrap();
    std::fs::canonicalize(&moved_dir).unwrap().to_string_lossy().into_owned()
}

// Spawns "prime" in daemon.dir; on a "go" line it `cd`s into `moved`, echoes
// CWD_MOVED, then runs `then`. Returns once the marker has been seen.
fn spawn_prime_and_wait_for_cd(app: &mut Conn, daemon: &TestDaemon, moved: &str, then: &str) {
    app.spawn_term_with(
        "prime",
        &["/bin/sh", "-c", &format!("read _; cd '{moved}' && echo CWD_MOVED; {then}")],
        Spawn { cwd: Some(daemon.dir.to_string_lossy().into_owned()), ..Default::default() },
    );
    app.send(&Msg::Input { term_id: "prime".into(), bytes: b"go\n".to_vec() });

    let mut collected = Vec::new();
    app.collect_output_into(&mut collected, "prime", "prime cd marker", b"CWD_MOVED");
}

// Spawns "t2" inheriting prime's cwd, with no explicit cwd of its own, and waits
// for its `pwd` output to show `moved`.
fn expect_t2_to_inherit_prime_cwd(app: &mut Conn, moved: &str) {
    app.spawn_term_with(
        "t2",
        &["/bin/sh", "-c", "pwd"],
        Spawn { inherit_cwd_from: Some("prime".into()), ..Default::default() },
    );

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

// A new terminal spawned with inherit_cwd_from starts in the source term's
// CURRENT directory, including after the source has `cd`'d away from where it
// was originally spawned — proving this reflects live state, not spawn cwd.
#[test]
fn spawn_term_inherits_source_terms_live_cwd_after_cd() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();
    let moved = create_moved_dir(&daemon);

    // The prime term blocks for an input line, `cd`s away and echoes a marker
    // (only once the cd has actually completed — shell commands run sequentially
    // in one process, no fork/exec in between), then blocks again so it stays
    // alive as the inherit source.
    spawn_prime_and_wait_for_cd(&mut app, &daemon, &moved, "read _");

    expect_t2_to_inherit_prime_cwd(&mut app, &moved);
}

// An inherit_cwd_from pointing at an unknown term_id (never spawned, or already
// exited) is not an error: the daemon silently falls back to term::spawn's own
// default cwd, exactly like a spawn_term that never set the hint at all.
#[test]
fn spawn_term_falls_back_when_inherit_source_is_unknown() {
    let daemon = TestDaemon::start();
    let mut app = daemon.connect_app_drained();

    app.spawn_term_with(
        "t1",
        &["/bin/sh", "-c", "pwd"],
        Spawn { inherit_cwd_from: Some("no-such-term".into()), ..Default::default() },
    );

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
    let mut app = daemon.connect_app_drained();
    let moved = create_moved_dir(&daemon);

    // Prime runs `cat` as a foreground child that blocks on stdin after the cd —
    // so at inherit time it has a live foreground job, not a bare prompt.
    spawn_prime_and_wait_for_cd(&mut app, &daemon, &moved, "cat");

    expect_t2_to_inherit_prime_cwd(&mut app, &moved);
}
