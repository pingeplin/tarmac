// `tarmac hooks` (spec 2611.0010) on the real binary. Every command comes from
// `hooks_cmd`, which pins HOME, CLAUDE_CONFIG_DIR and the cwd to a scratch dir,
// so no test can reach the real `~/.claude`; `hooks run` meets only a double.

use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg};

mod common;
use common::hooks::{fixture, hooks_cmd, sandbox};
use common::{Answer, Double, OneAnswer, Report};

const NO_DAEMON: &str = "no tarmac daemon running";

/// What a hook run that waits for nothing may take beyond a bare `tarmac
/// --help` run (#505): the design's 200 ms. A connect retry until the hook's
/// 500 ms deadline adds at least 500 ms, and the wait for stdin adds 1 s. A
/// wait that adds less than this passes.
const NOT_WAITED: Duration = Duration::from_millis(200);

/// What a run may take beyond a control when it waits for the hook's whole
/// 500 ms deadline and no more. A deadline given to the answer again after a
/// slow handshake comes to about 815 ms.
const ONE_DEADLINE: Duration = Duration::from_millis(750);

fn stop_input(text: &str) -> Vec<u8> {
    serde_json::to_vec(&serde_json::json!({"hook_event_name": "Stop", "last_assistant_message": text})).unwrap()
}

/// A `Stop` input of exactly `len` bytes.
fn stop_input_of_len(len: usize) -> Vec<u8> {
    let bare = stop_input("").len();
    let input = stop_input(&"a".repeat(len - bare));
    assert_eq!(input.len(), len);
    input
}

/// `hooks run claude` for terminal t9, on an absent socket unless the test
/// sets one.
fn run_claude(dir: &Path) -> Command {
    let mut cmd = hooks_cmd(dir);
    cmd.env("TARMAC_TERM_ID", "t9").args(["run", "claude"]);
    cmd
}

/// The hook's own rule: exit 0 and nothing on stdout, whatever happened.
#[track_caller]
fn assert_silent_success(out: &Report, case: &str) {
    assert_eq!((out.code(), out.stdout.as_str()), (Some(0), ""), "{case}: stderr: {}", out.stderr);
}

/// No connection, as a test sees it: the socket is absent, and a hook that
/// tried to connect would have printed the no-daemon line.
#[track_caller]
fn assert_no_connection(out: &Report, case: &str) {
    assert!(!out.stderr.contains(NO_DAEMON), "{case}: it tried to connect: {}", out.stderr);
}

/// The fastest of `runs` runs of `run`, with every result. A debug binary
/// under a parallel `cargo test` can be slow to start, so a bound holds for
/// the fastest run; every time is printed for the record. Only `run` is
/// timed: what `setup` makes is made before the clock starts and dropped
/// after it stops, so a double's teardown is not counted as the cli's time.
fn fastest<S>(runs: usize, mut setup: impl FnMut() -> S, mut run: impl FnMut(&S) -> Report) -> (Duration, Vec<Report>) {
    let mut times = Vec::new();
    let mut outs = Vec::new();
    for _ in 0..runs {
        let fixture = setup();
        let started = Instant::now();
        outs.push(run(&fixture));
        times.push(started.elapsed());
    }
    eprintln!("run times: {times:?}");
    (times.iter().copied().min().unwrap_or(Duration::MAX), outs)
}

/// `pairs` runs of `run`, each right after a control run of `tarmac --help`
/// (it connects to nothing and only prints), with every result of `run` and
/// how much longer its fastest run took than the fastest control. The fastest
/// of each side leaves out the runs that load or a first start slowed, so an
/// absolute limit on `run` is not tripped by a slow machine. "Silent daemon ends after the deadline" and "Bad hook input never fails" stay
/// absolute: "Silent daemon ends after the deadline" also checks a floor of 450 ms, and both have about 0.5 s of
/// headroom over their waits. The control spawns as the runs do, one child at
/// a time (#190). Times are as in `fastest`.
fn beyond_control<S>(
    pairs: usize,
    mut setup: impl FnMut() -> S,
    mut run: impl FnMut(&S) -> Report,
) -> (Duration, Vec<Report>) {
    let (mut hook_times, mut control_times, mut outs) = (Vec::new(), Vec::new(), Vec::new());
    for _ in 0..pairs {
        let started = Instant::now();
        let _ = Report::of(common::tarmac().arg("--help"));
        control_times.push(started.elapsed());
        let fixture = setup();
        let started = Instant::now();
        outs.push(run(&fixture));
        hook_times.push(started.elapsed());
    }
    let best = |times: &[Duration]| times.iter().copied().min().unwrap_or(Duration::MAX);
    let (hook, control) = (best(&hook_times), best(&control_times));
    eprintln!("hook {hook_times:?}, control {control_times:?}, beyond control {:?}", hook.saturating_sub(control));
    (hook.saturating_sub(control), outs)
}

/// A daemon that takes the connection and says nothing, not even `hello_ok`.
fn silent_to_hello() -> Double {
    Double::start("tarmacd.sock", |peer| peer.hold())
}

fn run_against(double: &Double, input: Vec<u8>) -> Report {
    let dir = sandbox();
    Report::of_input(run_claude(&dir).env("TARMAC_SOCKET", &double.sock), input)
}

fn report(kind: &str, text: Option<&str>) -> Msg {
    Msg::Report { term_id: "t9".into(), kind: kind.into(), text: text.map(str::to_string) }
}

/// "Hooks run sends the mapped report".
#[test]
fn hooks_run_sends_the_message_of_its_input() {
    for (input, want, case) in [
        (stop_input("Done.\n\n  All   tests pass.\n"), report("done", Some("Done. All tests pass.")), "stop"),
        (fixture("stop"), report("done", Some("You picked red.")), "captured stop"),
        (fixture("notification-permission"), report("blocked", Some("Claude needs your permission")), "permission"),
        (fixture("user-prompt-submit"), report("clear", None), "prompt"),
        (
            fixture("session-start"),
            Msg::Resume {
                term_id: "t9".into(),
                cmd: Some("claude --resume 00000000-0000-0000-0000-000000000000".into()),
            },
            "captured session start",
        ),
    ] {
        let daemon = OneAnswer::acking();
        let out = run_against(&daemon.double, input);

        assert_silent_success(&out, case);
        assert_eq!(out.stderr, "", "{case}");
        let raw = daemon.sent();
        assert_eq!(proto::decode(&raw).unwrap(), want, "{case}");
        if want == report("clear", None) {
            assert!(!raw.windows(4).any(|w| w == b"text"), "{case}: a text key on the wire");
        }
    }
}

/// "No daemon is fast and silent".
#[test]
fn no_daemon_is_fast_silent_and_says_so_on_stderr() {
    let dead = sandbox().join("dead.sock");
    drop(std::os::unix::net::UnixListener::bind(&dead).unwrap());
    for sock in [sandbox().join("absent.sock"), dead] {
        let (beyond, outs) = beyond_control(5, sandbox, |dir| {
            Report::of_input(run_claude(dir).env("TARMAC_SOCKET", &sock), stop_input("Done."))
        });

        for out in &outs {
            assert_silent_success(out, "no daemon");
            let line = out.one_stderr_line();
            assert!(line.starts_with("tarmac: hooks run: ") && line.contains(NO_DAEMON), "{line}");
        }
        assert!(beyond < NOT_WAITED, "{}: the fastest run took {beyond:?} more than a control", sock.display());
    }
}

/// "Silent daemon ends after the deadline".
#[test]
fn a_daemon_that_never_answers_is_given_up_on_at_the_deadline() {
    // Whichever phase the deadline ends in, the line is the same.
    let daemons: [fn() -> Double; 3] = [
        || OneAnswer::start(Answer::Silence).double,
        silent_to_hello,
        || OneAnswer::start_late(Duration::from_millis(800), Answer::Silence).double,
    ];
    for start in daemons {
        let (best, outs) = fastest(3, start, |daemon| run_against(daemon, stop_input("Done.")));

        for out in &outs {
            assert_silent_success(out, "silent daemon");
            assert_eq!(out.one_stderr_line(), "tarmac: hooks run: no answer from the daemon in 500 ms\n");
        }
        assert!(
            best >= Duration::from_millis(450) && best <= Duration::from_millis(1000),
            "the fastest run took {best:?}"
        );
    }
}

// The deadline covers connect to answer: time spent in the handshake is not
// given again to the answer.
#[test]
fn one_deadline_spans_the_handshake_and_the_answer() {
    let (beyond, outs) = beyond_control(
        3,
        || OneAnswer::start_late(Duration::from_millis(300), Answer::Silence),
        |daemon| run_against(&daemon.double, stop_input("Done.")),
    );

    for out in &outs {
        assert_silent_success(out, "slow hello");
        assert_eq!(out.one_stderr_line(), "tarmac: hooks run: no answer from the daemon in 500 ms\n");
    }
    assert!(beyond <= ONE_DEADLINE, "the fastest run took {beyond:?} more than a control");
}

/// "Daemon refusal still exits 0".
#[test]
fn a_refusal_is_a_stderr_line_and_exit_0() {
    let daemon = OneAnswer::start(Answer::Reply(Msg::Err { msg: "unknown terminal: t9".into() }));
    let out = run_against(&daemon.double, stop_input("Done."));

    assert_silent_success(&out, "refusal");
    assert!(out.one_stderr_line().contains("unknown terminal: t9"), "{}", out.stderr);
}

/// "Missing terminal id exits fast with no connection".
#[test]
fn no_terminal_exits_at_once_without_reading_stdin() {
    for term_id in [None, Some("")] {
        let (beyond, outs) = beyond_control(5, sandbox, |dir| {
            let mut cmd = hooks_cmd(dir);
            if let Some(id) = term_id {
                cmd.env("TARMAC_TERM_ID", id);
            }
            Report::with_open_stdin(cmd.args(["run", "claude"]), Duration::from_secs(5)).expect("it exits")
        });

        for out in &outs {
            assert_silent_success(out, "no terminal");
            assert_no_connection(out, "no terminal");
        }
        assert!(beyond < NOT_WAITED, "{term_id:?}: the fastest run took {beyond:?} more than a control");
    }
}

/// The daemon gives no such id, so the hook is not in a Tarmac terminal.
#[test]
fn a_term_id_that_is_not_utf8_is_no_terminal() {
    use std::os::unix::ffi::OsStrExt;
    let dir = sandbox();
    let mut cmd = hooks_cmd(&dir);
    cmd.env("TARMAC_TERM_ID", std::ffi::OsStr::from_bytes(b"t\xff9"));
    let out = Report::of_input(cmd.args(["run", "claude"]), fixture("stop"));

    assert_silent_success(&out, "no terminal");
    assert_no_connection(&out, "no terminal");
}

/// "Bad hook input never fails".
#[test]
fn s24_bad_input_exits_0_without_connecting() {
    for (input, case) in [
        (Vec::new(), "empty"),
        (b"not json".to_vec(), "not json"),
        (b"[]".to_vec(), "an array"),
        (br#"{"hook_event_name": 7}"#.to_vec(), "a number as the event"),
        (
            br#"{"hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "waiting"}"#
                .to_vec(),
            "idle",
        ),
        (stop_input_of_len((4 << 20) + 1), "over 4 MiB"),
    ] {
        let out = Report::of_input(&mut run_claude(&sandbox()), input);

        assert_silent_success(&out, case);
        assert_no_connection(&out, case);
    }
}

/// "Bad hook input never fails".
// The words name the size, so a cut input is not read as one that ends early.
#[test]
fn an_input_one_byte_over_4_mib_is_refused_by_its_size() {
    let out = Report::of_input(&mut run_claude(&sandbox()), stop_input_of_len((4 << 20) + 1));

    assert_silent_success(&out, "over 4 MiB");
    assert_eq!(out.one_stderr_line(), "tarmac: hooks run: the input is over 4194304 bytes\n");
}

// 2611.0011 "Refused session id does not connect"
#[test]
fn a_refused_session_id_says_so_and_does_not_connect() {
    let mut input: serde_json::Value = serde_json::from_slice(&fixture("session-start")).unwrap();
    input["session_id"] = "a;b".into();
    let out = Report::of_input(&mut run_claude(&sandbox()), serde_json::to_vec(&input).unwrap());

    assert_silent_success(&out, "a;b");
    assert_eq!(out.one_stderr_line(), "tarmac: hooks run: session_id refused\n");
    assert_no_connection(&out, "a;b");
}

/// "Bad hook input never fails".
// The control of the limit case, so that one cannot pass on a parse failure.
#[test]
fn an_input_of_exactly_4_mib_is_sent() {
    let out = Report::of_input(&mut run_claude(&sandbox()), stop_input_of_len(4 << 20));

    assert_silent_success(&out, "4 MiB");
    assert!(out.stderr.contains(NO_DAEMON), "{}", out.stderr);
}

/// "Bad hook input never fails".
#[test]
fn a_stdin_that_never_closes_ends_within_the_wait() {
    let (best, outs) = fastest(3, sandbox, |dir| {
        Report::with_open_stdin(&mut run_claude(dir), Duration::from_secs(5)).expect("it exits")
    });

    for out in &outs {
        assert_silent_success(out, "open stdin");
        assert_no_connection(out, "open stdin");
    }
    assert!(best <= Duration::from_millis(1500), "the fastest run took {best:?}");
}

/// "Bad hook arguments never fail".
#[test]
fn bad_arguments_exit_0_with_one_stderr_line() {
    for args in [&["run"][..], &["run", "codex"], &["run", "cursor"], &["run", "claude", "extra"]] {
        let out = Report::of_input(hooks_cmd(&sandbox()).env("TARMAC_TERM_ID", "t9").args(args), stop_input("Done."));

        let case = format!("{args:?}");
        assert_silent_success(&out, &case);
        out.one_stderr_line();
        assert_no_connection(&out, &case);
    }
}

/// "Bad hook arguments never fail".
#[test]
fn an_agent_other_than_claude_is_named_as_unknown() {
    let out =
        Report::of_input(hooks_cmd(&sandbox()).env("TARMAC_TERM_ID", "t9").args(["run", "codex"]), stop_input("Done."));

    assert_silent_success(&out, "codex");
    assert_eq!(out.one_stderr_line(), "tarmac: hooks run: unknown agent 'codex' (claude)\n");
}
