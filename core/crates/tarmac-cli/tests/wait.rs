// `tarmac wait` (spec 2611.0012). The daemon modes run against a daemon
// double; `--changed` runs on temp files, with a double that must see no
// connection.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use tarmac_protocol::Msg;

mod common;
use common::frames::{bell, exit, term_report};
use common::{
    Double, Report, Step, Streamer, Then, assert_never_answered, assert_no_answer, assert_usage, scratch, start,
    tarmac, tarmac_at, untouched,
};

const NOT_ANSWERED: &str = "tarmac: wait: timed out before the daemon answered\n";

fn subscribe(kinds: &[&str]) -> Msg {
    Msg::Subscribe { kinds: Some(kinds.iter().map(ToString::to_string).collect()), term_id: Some("t9".into()) }
}

// "Wait exit prints code or signal"
#[test]
fn an_exit_prints_its_code() {
    for (frames, stdout) in [
        (vec![Msg::Ack, exit("t9", Some(3))], "{\"code\":3}\n"),
        (vec![Msg::Ack, exit("t9", None)], "{\"signal\":true}\n"),
        (vec![exit("t9", Some(3)), Msg::Ack], "{\"code\":3}\n"),
    ] {
        let daemon = Streamer::holding(frames);

        let out = daemon.run(&["wait", "--exit", "t9"]);

        assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), stdout, ""));
        assert_eq!(daemon.request().0, subscribe(&["exit"]));
    }
}

// "Wait report prints the matching report"
#[test]
fn a_report_of_the_kind_prints_it_and_others_are_skipped() {
    let blocked = term_report("t9", Some("blocked"), Some("May I?"), Some("claude"), true);
    for frames in [
        vec![
            Msg::Ack,
            term_report("t9", Some("done"), None, None, false),
            term_report("t9", None, None, None, false),
            blocked.clone(),
        ],
        vec![blocked.clone(), Msg::Ack],
    ] {
        let daemon = Streamer::holding(frames);

        let out = daemon.run(&["wait", "--report", "blocked", "--term", "t9"]);

        assert_eq!(out.code(), Some(0), "{}", out.stderr);
        assert_eq!(
            out.stdout,
            "{\"kind\":\"blocked\",\"text\":\"May I?\",\"proc\":\"claude\",\"at_ms\":1700000000000,\"read\":true}\n"
        );
        assert_eq!(daemon.request().0, subscribe(&["report", "exit"]));
    }
}

#[test]
fn a_report_with_no_text_or_proc_has_no_key_for_them() {
    let daemon = Streamer::writing(vec![Msg::Ack, term_report("t9", Some("done"), None, None, false)]);

    let out = daemon.run(&["wait", "--report", "done", "--term", "t9"]);

    assert_eq!(out.stdout, "{\"kind\":\"done\",\"at_ms\":1700000000000,\"read\":false}\n");
}

// "Wait bell exits on first bell"
#[test]
fn a_bell_ends_the_wait_and_prints_nothing() {
    let daemon = Streamer::holding(vec![Msg::Ack, bell("t9")]);

    let out = daemon.run(&["wait", "--bell", "t9"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "", ""));
    assert_eq!(daemon.request().0, subscribe(&["bell", "exit"]));
}

#[test]
fn frames_of_another_terminal_are_skipped() {
    let daemon = Streamer::holding(vec![Msg::Ack, exit("t8", Some(1)), exit("t9", Some(2))]);

    let out = daemon.run(&["wait", "--exit", "t9"]);

    assert_eq!(out.stdout, "{\"code\":2}\n");
}

// "Unknown terminal or kind is refused"
#[test]
fn an_unknown_terminal_is_printed_and_exits_1() {
    let daemon = Streamer::writing(vec![Msg::Err { msg: "unknown terminal: t9".into() }]);

    let out = daemon.run(&["wait", "--exit", "t9"]);

    assert_eq!((out.code(), out.stderr.as_str()), (Some(1), "tarmac: unknown terminal: t9\n"));
}

// "Wait for an ended terminal exits 1"
#[test]
fn an_exit_ends_a_wait_for_a_bell_or_a_report() {
    for args in [&["--bell", "t9"][..], &["--report", "done", "--term", "t9"]] {
        let daemon = Streamer::holding(vec![Msg::Ack, exit("t9", Some(0))]);

        let out = Report::of(tarmac_at(&daemon.double.sock).arg("wait").args(args));

        assert_eq!(
            (out.code(), out.stdout.as_str(), out.stderr.as_str()),
            (Some(1), "", "tarmac: terminal t9 exited\n"),
            "{args:?}"
        );
    }
}

fn timed(daemon: &Streamer, args: &[&str]) -> (Report, Duration) {
    let started = Instant::now();
    let out = daemon.run(args);
    (out, started.elapsed())
}

/// `wait --exit t9 --timeout 300` against a fresh `daemon()`, three times:
/// each run exits 124 with `stderr` and no sooner than 300 ms, and the
/// fastest within 800 ms. Only the fastest is bounded above: the first start
/// of the debug binary in a test process can take 0.5 s or more (#406).
#[track_caller]
fn assert_times_out_at_300_ms(daemon: impl Fn() -> Double, stderr: &str) {
    let mut times = Vec::new();
    for _ in 0..3 {
        let daemon = daemon();
        let started = Instant::now();
        let out = Report::of(tarmac_at(&daemon.sock).args(["wait", "--exit", "t9", "--timeout", "300"]));
        let took = started.elapsed();
        assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(124), "", stderr));
        assert!(took >= Duration::from_millis(300), "{took:?}");
        times.push(took);
    }
    eprintln!("run times: {times:?}");
    assert!(times.iter().min().is_some_and(|t| *t < Duration::from_millis(800)), "{times:?}");
}

// "Wait timeouts exit 124"
#[test]
fn a_timeout_after_the_ack_exits_124_with_nothing_printed() {
    assert_times_out_at_300_ms(|| Streamer::holding(vec![Msg::Ack]).double, "");
}

// "Wait timeouts exit 124"
#[test]
fn a_timeout_before_the_ack_exits_124_with_one_line() {
    assert_times_out_at_300_ms(|| Streamer::start(vec![], Then::Hold).double, NOT_ANSWERED);
}

// "Wait timeouts exit 124"
#[test]
fn with_no_timeout_a_daemon_that_never_answers_is_the_no_answer_line() {
    assert_never_answered(&["wait", "--exit", "t9"]);
}

// D14: with a `--timeout` past the 5 s wait, a silent daemon is still the
// older-daemon line, not a timeout.
#[test]
fn a_timeout_longer_than_the_5_s_wait_still_gives_the_no_answer_line() {
    assert_never_answered(&["wait", "--exit", "t9", "--timeout", "6000"]);
}

// "Wait timeouts exit 124", in the handshake: no `hello_ok` is the same as no `ack`.
#[test]
fn a_daemon_silent_to_hello_is_a_timeout_or_the_no_answer_line() {
    let daemon = Double::start("tarmacd.sock", |peer| peer.hold());
    let started = Instant::now();
    assert_no_answer(&Report::of(tarmac_at(&daemon.sock).args(["wait", "--exit", "t9"])), started);

    assert_times_out_at_300_ms(|| Double::start("tarmacd.sock", |peer| peer.hold()), NOT_ANSWERED);
}

// D14: the deadline counts from the start, the handshake included.
#[test]
fn the_timeout_counts_a_slow_handshake() {
    let daemon = Streamer::start_late(Duration::from_millis(400), vec![Step::Write(Msg::Ack)], Then::Hold);

    let (out, took) = timed(&daemon, &["wait", "--exit", "t9", "--timeout", "700"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(124), "", ""));
    assert!(took < Duration::from_millis(1000), "{took:?}");
}

// After `ack` a wait with no `--timeout` has no time limit.
#[test]
fn a_wait_quiet_for_longer_than_5_s_goes_on() {
    let daemon = Streamer::start(
        vec![Step::Write(Msg::Ack), Step::Pause(Duration::from_millis(5500)), Step::Write(exit("t9", Some(0)))],
        Then::Hold,
    );

    let out = daemon.run(&["wait", "--exit", "t9"]);

    assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), "{\"code\":0}\n", ""));
}

// "Lost daemon connection exits 1"
#[test]
fn the_daemon_going_away_or_a_lag_exits_1() {
    let lost = Streamer::writing(vec![Msg::Ack]);
    let out = lost.run(&["wait", "--exit", "t9"]);
    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().starts_with("tarmac: daemon connection lost: "), "{}", out.stderr);

    let lagged = Streamer::writing(vec![Msg::Ack, Msg::Err { msg: "lagged".into() }]);
    let out = lagged.run(&["wait", "--exit", "t9"]);
    assert_eq!(
        (out.code(), out.stderr.as_str()),
        (Some(1), "tarmac: the daemon dropped this stream: it fell behind (lagged)\n")
    );
}

// "Bad wait usage exits 2": the whole matrix is `parse`'s unit test.
#[test]
fn a_usage_error_exits_2_with_no_connection() {
    let daemon = Streamer::writing(vec![Msg::Ack]);

    let out = Report::of(tarmac_at(&daemon.double.sock).args(["wait", "--report", "later", "--term", "t1"]));

    assert_usage(&out, "wait");
    assert!(out.stderr.contains("--changed PATH [--settle MS] [--timeout MS]"), "{}", out.stderr);
    assert!(untouched(&daemon.double));
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
    let (out, took, _) = changed_timed(path, args, after, act);
    (out, took)
}

/// As `changed_with`, and also how long the exit came after `act` returned. A
/// sleep ends late on a loaded machine, so "the whole run minus `after`" counts
/// that lateness as the CLI's (#469).
fn changed_timed(path: &Path, args: &[&str], after: Duration, act: impl FnOnce()) -> (Output, Duration, Duration) {
    let daemon = Streamer::writing(vec![Msg::Ack]);
    let started = Instant::now();
    let child = start(tarmac_at(&daemon.double.sock).args(["wait", "--changed"]).arg(path).args(args));
    std::thread::sleep(after);
    act();
    let acted = Instant::now();
    let out = child.wait_with_output().unwrap();
    let (took, since_act) = (started.elapsed(), acted.elapsed());
    assert!(untouched(&daemon.double));
    (out, took, since_act)
}

fn append(path: &Path) {
    use std::io::Write;
    std::fs::OpenOptions::new().append(true).open(path).unwrap().write_all(b"x").unwrap();
}

fn stdout(out: &Output) -> &str {
    std::str::from_utf8(&out.stdout).unwrap()
}

// "Wait changed detects each kind of change"
#[test]
fn a_change_of_the_file_ends_the_wait() {
    let dir = scratch();
    #[expect(clippy::type_complexity, reason = "predates the lint; a design change, not part of #468")]
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
        (
            "touch",
            Box::new(|f| File::options().write(true).open(f).unwrap().set_modified(SystemTime::now()).unwrap()),
            "{\"deleted\":false}\n",
        ),
    ];
    for (name, act, want) in cases {
        let file = old_file(&dir, &format!("{name}.txt"));

        let (out, _) = changed_with(&file, &["--timeout", "5000"], Duration::from_millis(300), || act(&file));

        assert_eq!(
            (out.status.code(), stdout(&out)),
            (Some(0), want),
            "{name}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

// "Wait changed detects each kind of change" (c)
#[test]
fn a_missing_file_that_is_made_ends_the_wait() {
    let file = scratch().join("later.txt");

    let (out, _) =
        changed_with(&file, &["--timeout", "5000"], Duration::from_millis(300), || std::fs::write(&file, "a").unwrap());

    assert_eq!((out.status.code(), stdout(&out)), (Some(0), "{\"deleted\":false}\n"));
}

// "Wait changed polls and settles on time"
#[test]
fn a_change_in_the_slow_stage_ends_the_wait() {
    let dir = scratch();
    let file = old_file(&dir, "slow.txt");

    let (out, _, late) = changed_timed(&file, &["--timeout", "6000"], Duration::from_millis(2200), || {
        let other = dir.join("slow.new");
        std::fs::write(&other, "xyz").unwrap();
        std::fs::rename(&other, &file).unwrap();
    });

    assert_eq!(out.status.code(), Some(0));
    // The cadence itself has a unit test with no clock (`report_samples`). This
    // limit only says that the wait does not hang: the first one, 450 ms from
    // the start of the run, was too tight for a loaded CI machine (#469).
    assert!(late < Duration::from_millis(1250), "the exit came {late:?} after the rename");
}

// "Wait changed polls and settles on time"
#[test]
fn settle_waits_for_the_last_change() {
    let file = old_file(&scratch(), "settle.txt");

    let (out, took) =
        changed_with(&file, &["--settle", "500", "--timeout", "5000"], Duration::from_millis(300), || {
            append(&file);
            std::thread::sleep(Duration::from_millis(300));
            append(&file);
        });

    assert_eq!((out.status.code(), stdout(&out)), (Some(0), "{\"deleted\":false}\n"));
    assert!(took >= Duration::from_millis(1100), "{took:?}");
}

/// A file whose mtime is half a second past a whole second 3 s back, so a
/// change of 1 µs keeps its seconds.
fn file_at_half_second(dir: &Path, name: &str) -> (PathBuf, SystemTime) {
    let path = dir.join(name);
    std::fs::write(&path, "abc").unwrap();
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() - 3;
    let mtime = UNIX_EPOCH + Duration::new(secs, 500_000_000);
    File::options().write(true).open(&path).unwrap().set_modified(mtime).unwrap();
    (path, mtime)
}

// "Wait changed polls and settles on time": each fact of a sample counts alone.
#[test]
fn a_change_of_the_size_alone_or_of_the_mtime_below_a_second_ends_the_wait() {
    let dir = scratch();
    #[expect(clippy::type_complexity, reason = "predates the lint; a design change, not part of #468")]
    let cases: Vec<(&str, Box<dyn Fn(&Path, SystemTime)>)> = vec![
        (
            "size",
            Box::new(|f, mtime| {
                std::fs::write(f, "abcd").unwrap();
                File::options().write(true).open(f).unwrap().set_modified(mtime).unwrap();
            }),
        ),
        (
            "nsec",
            Box::new(|f, mtime| {
                File::options().write(true).open(f).unwrap().set_modified(mtime + Duration::from_micros(1)).unwrap();
            }),
        ),
    ];
    for (name, act) in cases {
        let (file, mtime) = file_at_half_second(&dir, &format!("{name}.txt"));

        let (out, _) = changed_with(&file, &["--timeout", "3000"], Duration::from_millis(300), || act(&file, mtime));

        assert_eq!((out.status.code(), stdout(&out)), (Some(0), "{\"deleted\":false}\n"), "{name}");
    }
}

// D17: a path below a file is missing, not a stat error.
#[test]
fn a_path_below_a_file_is_missing() {
    let file = scratch().join("plain.txt");
    std::fs::write(&file, "a").unwrap();

    let (out, _) = changed_with(&file.join("x"), &["--timeout", "500"], Duration::ZERO, || {});

    assert_eq!((out.status.code(), stdout(&out), String::from_utf8_lossy(&out.stderr).as_ref()), (Some(124), "", ""));
}

// "Change before the start does not count"
#[test]
fn a_change_before_the_start_does_not_count() {
    let file = scratch().join("before.txt");
    std::fs::write(&file, "a").unwrap();

    let (out, _) = changed_with(&file, &["--timeout", "600"], Duration::ZERO, || {});

    assert_eq!((out.status.code(), stdout(&out)), (Some(124), ""));
}

// "Timeout wins while change is settling"
#[test]
fn a_timeout_while_it_settles_exits_124() {
    let file = old_file(&scratch(), "unsettled.txt");

    let (out, took) =
        changed_with(&file, &["--settle", "1000", "--timeout", "800"], Duration::from_millis(200), || {
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

// "Wait changed stat error exits 1"
#[test]
fn a_stat_error_that_is_not_missing_exits_1() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch().join("closed");
    std::fs::create_dir(&dir).unwrap();
    std::fs::write(dir.join("f.txt"), "a").unwrap();
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();
    let _mode = Mode(dir.clone());

    let (out, _) = changed_with(&dir.join("f.txt"), &["--timeout", "2000"], Duration::ZERO, || {});

    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        String::from_utf8_lossy(&out.stderr),
        format!("tarmac: cannot stat {}: Permission denied (os error 13)\n", dir.join("f.txt").display())
    );
}

#[test]
fn the_helper_samples_at_the_poll_cadence_and_ends_when_its_reader_goes() {
    use std::io::BufRead;
    let file = old_file(&scratch(), "a.txt");
    let mut helper = start(tarmac().arg("__wait-changed-stat").arg(&file));
    let mut lines = std::io::BufReader::new(helper.stdout.take().unwrap()).lines();
    let first = lines.next().unwrap().unwrap();
    let window = Instant::now() + Duration::from_secs(1);
    let mut count = 1;
    while Instant::now() < window {
        assert_eq!(lines.next().unwrap().unwrap(), first);
        count += 1;
    }
    drop(lines);
    let until = Instant::now() + Duration::from_millis(400);
    let mut ended = helper.try_wait().unwrap();
    while ended.is_none() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(20));
        ended = helper.try_wait().unwrap();
    }
    let _ = helper.kill();
    let _ = helper.wait();

    assert!((2..=13).contains(&count), "{count} samples in 1 s");
    assert_eq!(ended.and_then(|s| s.code()), Some(0), "the helper did not end once its reader went");
}

// #361: the stat runs in a helper process, so a stat that hangs cannot hold
// the wait past its --timeout. The path goes to it as given: making a
// relative path absolute reads the cwd, which can hang too.
#[test]
fn the_stat_runs_in_one_helper_process_given_the_path_as_typed() {
    let dir = scratch();
    old_file(&dir, "a.txt");
    let wait = start(tarmac().args(["wait", "--changed", "a.txt", "--timeout", "3000"]).current_dir(&dir));
    let children = || {
        let out =
            std::process::Command::new("pgrep").args(["-l", "-f", "-P"]).arg(wait.id().to_string()).output().unwrap();
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let until = Instant::now() + Duration::from_millis(2500);
    let mut listed = children();
    while listed.is_empty() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(50));
        listed = children();
    }
    let out = wait.wait_with_output().unwrap();

    assert_eq!(listed.lines().count(), 1, "{listed}");
    assert!(listed.trim_end().ends_with("__wait-changed-stat a.txt"), "{listed}");
    assert_eq!(out.status.code(), Some(124));
}
