// `tarmac wait` (spec 2611.0012). The daemon modes run against a daemon
// double; `--changed` runs on temp files, with a double that must see no
// connection.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant, SystemTime};

use tarmac_protocol::Msg;

mod common;
use common::{Report, Step, Streamer, Then, scratch, start, tarmac_at, untouched};

const USAGE: &str =
    "tarmac: usage: tarmac wait --exit ID | --bell ID | --report blocked|done --term ID | --changed PATH [--settle MS]  [--timeout MS]\n";
const NOT_ANSWERED: &str = "tarmac: wait: timed out before the daemon answered\n";

fn exit(code: Option<i64>) -> Msg {
    Msg::Exit { term_id: "t9".into(), code, board_id: None }
}

fn report(kind: Option<&str>, text: Option<&str>, proc: Option<&str>, read: bool) -> Msg {
    Msg::TermReport {
        term_id: "t9".into(),
        kind: kind.map(str::to_string),
        text: text.map(str::to_string),
        at_ms: kind.map(|_| 1_700_000_000_000),
        proc: proc.map(str::to_string),
        read,
        board_id: None,
        cwd: None,
    }
}

fn subscribe(kinds: &[&str]) -> Msg {
    Msg::Subscribe { kinds: Some(kinds.iter().map(|k| k.to_string()).collect()), term_id: Some("t9".into()) }
}

// S9
#[test]
fn s9_an_exit_prints_its_code() {
    for (frames, stdout) in [
        (vec![Msg::Ack, exit(Some(3))], "{\"code\":3}\n"),
        (vec![Msg::Ack, exit(None)], "{\"signal\":true}\n"),
        (vec![exit(Some(3)), Msg::Ack], "{\"code\":3}\n"),
    ] {
        let daemon = Streamer::start(frames.into_iter().map(Step::Write).collect(), Then::Hold);

        let out = daemon.run(&["wait", "--exit", "t9"]);

        assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), stdout, ""));
        assert_eq!(daemon.request().0, subscribe(&["exit"]));
    }
}

// S10
#[test]
fn s10_a_report_of_the_kind_prints_it_and_others_are_skipped() {
    let blocked = report(Some("blocked"), Some("May I?"), Some("claude"), true);
    for frames in [
        vec![Msg::Ack, report(Some("done"), None, None, false), report(None, None, None, false), blocked.clone()],
        vec![blocked.clone(), Msg::Ack],
    ] {
        let daemon = Streamer::start(frames.into_iter().map(Step::Write).collect(), Then::Hold);

        let out = daemon.run(&["wait", "--report", "blocked", "--term", "t9"]);

        assert_eq!(out.code(), Some(0), "{}", out.stderr);
        assert_eq!(out.stdout, "{\"kind\":\"blocked\",\"text\":\"May I?\",\"proc\":\"claude\",\"at_ms\":1700000000000,\"read\":true}\n");
        assert_eq!(daemon.request().0, subscribe(&["report", "exit"]));
    }
}

#[test]
fn a_report_with_no_text_or_proc_has_no_key_for_them() {
    let daemon = Streamer::writing(vec![Msg::Ack, report(Some("done"), None, None, false)]);

    let out = daemon.run(&["wait", "--report", "done", "--term", "t9"]);

    assert_eq!(out.stdout, "{\"kind\":\"done\",\"at_ms\":1700000000000,\"read\":false}\n");
}

// S11
#[test]
fn s11_a_bell_ends_the_wait_and_prints_nothing() {
    let daemon = Streamer::start(vec![Step::Write(Msg::Ack), Step::Write(Msg::Bell { term_id: "t9".into(), board_id: None })], Then::Hold);

    let out = daemon.run(&["wait", "--bell", "t9"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    assert_eq!(daemon.request().0, subscribe(&["bell", "exit"]));
}

#[test]
fn frames_of_another_terminal_are_skipped() {
    let other = Msg::Exit { term_id: "t8".into(), code: Some(1), board_id: None };
    let daemon = Streamer::start(vec![Step::Write(Msg::Ack), Step::Write(other), Step::Write(exit(Some(2)))], Then::Hold);

    let out = daemon.run(&["wait", "--exit", "t9"]);

    assert_eq!(out.stdout, "{\"code\":2}\n");
}

// S29
#[test]
fn s29_an_unknown_terminal_is_printed_and_exits_1() {
    let daemon = Streamer::writing(vec![Msg::Err { msg: "unknown terminal: t9".into() }]);

    let out = daemon.run(&["wait", "--exit", "t9"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: unknown terminal: t9\n"));
}

// S30
#[test]
fn s30_an_exit_ends_a_wait_for_a_bell_or_a_report() {
    for args in [&["--bell", "t9"][..], &["--report", "done", "--term", "t9"]] {
        let daemon = Streamer::start(vec![Step::Write(Msg::Ack), Step::Write(exit(Some(0)))], Then::Hold);

        let out = Report::of(tarmac_at(&daemon.double.sock).arg("wait").args(args));

        assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(1), "", "tarmac: terminal t9 exited\n"), "{args:?}");
    }
}

fn timed(daemon: &Streamer, args: &[&str]) -> (Report, Duration) {
    let started = Instant::now();
    let out = daemon.run(args);
    (out, started.elapsed())
}

// S31
#[test]
fn s31_a_timeout_after_the_ack_exits_124_with_nothing_printed() {
    let daemon = Streamer::start(vec![Step::Write(Msg::Ack)], Then::Hold);

    let (out, took) = timed(&daemon, &["wait", "--exit", "t9", "--timeout", "300"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(124), "", ""));
    assert!(took >= Duration::from_millis(300) && took < Duration::from_millis(800), "{took:?}");
}

// S31
#[test]
fn s31_a_timeout_before_the_ack_exits_124_with_one_line() {
    let daemon = Streamer::start(vec![], Then::Hold);

    let (out, took) = timed(&daemon, &["wait", "--exit", "t9", "--timeout", "300"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(124), "", NOT_ANSWERED));
    assert!(took >= Duration::from_millis(300) && took < Duration::from_millis(800), "{took:?}");
}

// S31
#[test]
fn s31_with_no_timeout_a_daemon_that_never_answers_is_the_no_answer_line() {
    let daemon = Streamer::start(vec![], Then::Hold);

    let (out, took) = timed(&daemon, &["wait", "--exit", "t9"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: no answer from the daemon in 5 s (an older daemon)\n"));
    assert!(took >= Duration::from_secs(5), "{took:?}");
}

// S32
#[test]
fn s32_the_daemon_going_away_or_a_lag_exits_1() {
    let lost = Streamer::writing(vec![Msg::Ack]);
    let out = lost.run(&["wait", "--exit", "t9"]);
    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().starts_with("tarmac: daemon connection lost: "), "{}", out.stderr);

    let lagged = Streamer::writing(vec![Msg::Ack, Msg::Err { msg: "lagged".into() }]);
    let out = lagged.run(&["wait", "--exit", "t9"]);
    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: the daemon dropped this stream: it fell behind (lagged)\n"));
}

// S33
#[test]
fn s33_a_usage_error_exits_2_with_no_connection() {
    let cases: &[&[&str]] = &[
        &[],
        &["--exit"],
        &["--exit", "t1", "--bell", "t1"],
        &["--report", "later", "--term", "t1"],
        &["--report", "done"],
        &["--exit", "t1", "--term", "t1"],
        &["--exit", "t1", "--settle", "5"],
        &["--exit", "t1", "--timeout", "0"],
        &["--exit", "t1", "--timeout", "abc"],
        &["--changed"],
        &["--changed", "/a", "--settle", "0"],
        &["--exit", "t1", "--exit", "t2"],
        &["--exit", "t1", "extra"],
    ];
    for args in cases {
        let daemon = Streamer::writing(vec![Msg::Ack]);

        let out = Report::of(tarmac_at(&daemon.double.sock).arg("wait").args(*args));

        assert_eq!(out.code(), Some(2), "{args:?}");
        assert_eq!(out.one_stderr_line(), USAGE, "{args:?}");
        assert!(untouched(&daemon.double), "{args:?}");
    }
}

/// A file in a scratch dir whose mtime is 3 s back, so a change made now
/// is a change of mtime as well.
fn old_file(dir: &Path, name: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, "abc").unwrap();
    File::options().write(true).open(&path).unwrap().set_modified(SystemTime::now() - Duration::from_secs(3)).unwrap();
    path
}

/// `wait --changed` on `path`, with `args` after it, while `act` runs
/// `after` the start. The double on its socket must see no connection.
fn changed_with(path: &Path, args: &[&str], after: Duration, act: impl FnOnce()) -> (Output, Duration) {
    let daemon = Streamer::writing(vec![Msg::Ack]);
    let started = Instant::now();
    let child = start(tarmac_at(&daemon.double.sock).args(["wait", "--changed"]).arg(path).args(args));
    std::thread::sleep(after);
    act();
    let out = child.wait_with_output().unwrap();
    let took = started.elapsed();
    assert!(untouched(&daemon.double));
    (out, took)
}

fn append(path: &Path) {
    use std::io::Write;
    std::fs::OpenOptions::new().append(true).open(path).unwrap().write_all(b"x").unwrap();
}

fn stdout(out: &Output) -> &str {
    std::str::from_utf8(&out.stdout).unwrap()
}

// S13
#[test]
fn s13_a_change_of_the_file_ends_the_wait() {
    let dir = scratch();
    let cases: Vec<(&str, Box<dyn FnOnce(&Path)>, &str)> = vec![
        ("append", Box::new(append), "{\"deleted\":false}\n"),
        (
            "replace",
            Box::new(|f| {
                let other = f.with_extension("new");
                std::fs::write(&other, "xyz").unwrap();
                let mtime = std::fs::metadata(f).unwrap().modified().unwrap();
                File::options().write(true).open(&other).unwrap().set_modified(mtime).unwrap();
                std::fs::rename(&other, f).unwrap();
            }),
            "{\"deleted\":false}\n",
        ),
        ("delete", Box::new(|f| std::fs::remove_file(f).unwrap()), "{\"deleted\":true}\n"),
        ("touch", Box::new(|f| File::options().write(true).open(f).unwrap().set_modified(SystemTime::now()).unwrap()), "{\"deleted\":false}\n"),
    ];
    for (name, act, want) in cases {
        let file = old_file(&dir, &format!("{name}.txt"));

        let (out, _) = changed_with(&file, &["--timeout", "5000"], Duration::from_millis(300), || act(&file));

        assert_eq!((out.status.code(), stdout(&out)), (Some(0), want), "{name}: {}", String::from_utf8_lossy(&out.stderr));
    }
}

// S13 (c)
#[test]
fn s13_a_missing_file_that_is_made_ends_the_wait() {
    let file = scratch().join("later.txt");

    let (out, _) = changed_with(&file, &["--timeout", "5000"], Duration::from_millis(300), || std::fs::write(&file, "a").unwrap());

    assert_eq!((out.status.code(), stdout(&out)), (Some(0), "{\"deleted\":false}\n"));
}

// S27
#[test]
fn s27_a_change_after_2_s_is_seen_within_one_slow_poll() {
    let dir = scratch();
    let file = old_file(&dir, "slow.txt");

    let (out, took) = changed_with(&file, &["--timeout", "6000"], Duration::from_millis(2200), || {
        let other = dir.join("slow.new");
        std::fs::write(&other, "xyz").unwrap();
        std::fs::rename(&other, &file).unwrap();
    });

    assert_eq!(out.status.code(), Some(0));
    let late = took.saturating_sub(Duration::from_millis(2200));
    assert!(late < Duration::from_millis(450), "the exit came {late:?} after the rename");
}

// S27
#[test]
fn s27_settle_waits_for_the_last_change() {
    let file = old_file(&scratch(), "settle.txt");

    let (out, took) = changed_with(&file, &["--settle", "500", "--timeout", "5000"], Duration::from_millis(300), || {
        append(&file);
        std::thread::sleep(Duration::from_millis(300));
        append(&file);
    });

    assert_eq!((out.status.code(), stdout(&out)), (Some(0), "{\"deleted\":false}\n"));
    assert!(took >= Duration::from_millis(1100), "{took:?}");
}

// S28
#[test]
fn s28_a_change_before_the_start_does_not_count() {
    let file = scratch().join("before.txt");
    std::fs::write(&file, "a").unwrap();

    let (out, _) = changed_with(&file, &["--timeout", "600"], Duration::ZERO, || {});

    assert_eq!((out.status.code(), stdout(&out)), (Some(124), ""));
}

// S44
#[test]
fn s44_a_timeout_while_it_settles_exits_124() {
    let file = old_file(&scratch(), "unsettled.txt");

    let (out, took) = changed_with(&file, &["--settle", "1000", "--timeout", "800"], Duration::from_millis(200), || {
        File::options().write(true).open(&file).unwrap().set_modified(SystemTime::now()).unwrap();
    });

    assert_eq!((out.status.code(), stdout(&out)), (Some(124), ""));
    assert!(took >= Duration::from_millis(800) && took < Duration::from_millis(1100), "{took:?}");
}

/// Gives a directory its mode back when the test ends, a panic included.
struct Mode(PathBuf);

impl Drop for Mode {
    fn drop(&mut self) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o755));
    }
}

// S34
#[test]
fn s34_a_stat_error_that_is_not_missing_exits_1() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch().join("closed");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("f.txt"), "a").unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
    let _mode = Mode(dir.clone());

    let (out, _) = changed_with(&dir.join("f.txt"), &["--timeout", "2000"], Duration::ZERO, || {});

    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).starts_with("tarmac: cannot stat "), "{}", String::from_utf8_lossy(&out.stderr));
}
