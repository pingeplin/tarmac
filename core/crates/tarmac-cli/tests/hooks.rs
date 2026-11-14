// `tarmac hooks` (spec 2611.0010) on the real binary. Every command comes from
// `hooks_cmd`, which pins HOME, CLAUDE_CONFIG_DIR and the cwd to a scratch dir,
// so no test can reach the real `~/.claude`; `hooks run` meets only a double.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use tarmac_protocol::{self as proto, Msg};

mod common;
use common::{Double, Report, hello_ok, scratch, tarmac};

const NO_DAEMON: &str = "no tarmac daemon running";

/// A scratch dir in its canonical form, so a path the cli prints compares
/// equal to one the test builds (`/var` is `/private/var` on macOS), with
/// the `home` and `proj` dirs of `hooks_cmd`.
fn sandbox() -> PathBuf {
    let dir = scratch().canonicalize().unwrap();
    for sub in ["home", "proj"] {
        std::fs::create_dir_all(dir.join(sub)).unwrap();
    }
    dir
}

/// `tarmac hooks`, with `dir/home` as HOME, `dir/proj` as the cwd, an empty
/// CLAUDE_CONFIG_DIR (unset, so HOME decides) and no TARMAC_TERM_ID.
fn hooks_cmd(dir: &Path) -> Command {
    for sub in ["home", "proj"] {
        std::fs::create_dir_all(dir.join(sub)).unwrap();
    }
    let mut cmd = tarmac();
    cmd.env("HOME", dir.join("home"))
        .env("CLAUDE_CONFIG_DIR", "")
        .env_remove("TARMAC_TERM_ID")
        .current_dir(dir.join("proj"))
        .arg("hooks");
    cmd
}

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

fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hooks").join(format!("{name}.json"))).unwrap()
}

/// `hooks run claude` for terminal t9, on an absent socket.
fn run_with_no_daemon(args: &[&str], input: Vec<u8>) -> Report {
    let dir = sandbox();
    Report::of_input(hooks_cmd(&dir).env("TARMAC_TERM_ID", "t9").args(args), input)
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
/// the fastest run; every time is printed for the record.
fn fastest(runs: usize, mut run: impl FnMut() -> Report) -> (Duration, Vec<Report>) {
    let mut times = Vec::new();
    let mut outs = Vec::new();
    for _ in 0..runs {
        let started = Instant::now();
        outs.push(run());
        times.push(started.elapsed());
    }
    eprintln!("run times: {times:?}");
    (times.iter().copied().min().unwrap_or(Duration::MAX), outs)
}

/// What the double does once the hook has said hello.
#[derive(Clone)]
enum Daemon {
    Answers(Msg),
    SilentAfterHello,
    SilentToHello,
}

fn daemon(kind: Daemon) -> Double {
    Double::start("tarmacd.sock", move |peer| {
        if let Daemon::SilentToHello = kind {
            return peer.hold();
        }
        let hello_ok = proto::encode(&hello_ok(None, None, None, None)).unwrap();
        if peer.read().is_none() || !peer.write(&hello_ok) || peer.read().is_none() {
            return;
        }
        match kind {
            Daemon::Answers(msg) => {
                peer.write(&proto::encode(&msg).unwrap());
                peer.drain();
            }
            _ => peer.hold(),
        }
    })
}

fn run_against(double: &Double, input: Vec<u8>) -> Report {
    let dir = sandbox();
    Report::of_input(
        hooks_cmd(&dir).env("TARMAC_SOCKET", &double.sock).env("TARMAC_TERM_ID", "t9").args(["run", "claude"]),
        input,
    )
}

/// The one frame after the hello, raw.
fn sent(double: &Double) -> Vec<u8> {
    let frames = double.frames();
    let (hello, rest) = frames.split_first().expect("a hello");
    assert!(matches!(proto::decode(hello).unwrap(), Msg::Hello { .. }));
    assert_eq!(rest.len(), 1, "one report");
    rest[0].clone()
}

fn report(kind: &str, text: Option<&str>) -> Msg {
    Msg::Report { term_id: "t9".into(), kind: kind.into(), text: text.map(str::to_string) }
}

// S6
#[test]
fn s6_hooks_run_sends_the_report_of_its_input() {
    for (input, want, case) in [
        (stop_input("Done.\n\n  All   tests pass.\n"), report("done", Some("Done. All tests pass.")), "stop"),
        (fixture("stop"), report("done", Some("You picked red.")), "captured stop"),
        (fixture("notification-permission"), report("blocked", Some("Claude needs your permission")), "permission"),
        (fixture("user-prompt-submit"), report("clear", None), "prompt"),
    ] {
        let double = daemon(Daemon::Answers(Msg::Ack));
        let out = run_against(&double, input);

        assert_silent_success(&out, case);
        assert_eq!(out.stderr, "", "{case}");
        let raw = sent(&double);
        assert_eq!(proto::decode(&raw).unwrap(), want, "{case}");
        if want == report("clear", None) {
            assert!(!raw.windows(4).any(|w| w == b"text"), "{case}: a text key on the wire");
        }
    }
}

// S20
#[test]
fn s20_no_daemon_is_fast_silent_and_says_so_on_stderr() {
    let dead = sandbox().join("dead.sock");
    drop(std::os::unix::net::UnixListener::bind(&dead).unwrap());
    for sock in [sandbox().join("absent.sock"), dead] {
        let (best, outs) = fastest(5, || {
            let dir = sandbox();
            Report::of_input(
                hooks_cmd(&dir).env("TARMAC_SOCKET", &sock).env("TARMAC_TERM_ID", "t9").args(["run", "claude"]),
                stop_input("Done."),
            )
        });

        for out in &outs {
            assert_silent_success(out, "no daemon");
            let line = out.one_stderr_line();
            assert!(line.starts_with("tarmac: hooks run: ") && line.contains(NO_DAEMON), "{line}");
        }
        assert!(best <= Duration::from_millis(200), "{}: the fastest run took {best:?}", sock.display());
    }
}

// S21
#[test]
fn s21_a_daemon_that_never_answers_is_given_up_on_at_the_deadline() {
    for (kind, want) in [
        (Daemon::SilentAfterHello, Some("tarmac: hooks run: no answer from the daemon in 500 ms\n")),
        (Daemon::SilentToHello, None),
    ] {
        let (best, outs) = fastest(3, || run_against(&daemon(kind.clone()), stop_input("Done.")));

        for out in &outs {
            assert_silent_success(out, "silent daemon");
            let line = out.one_stderr_line();
            assert!(line.starts_with("tarmac: hooks run: ") && !line.contains("5 s"), "{line}");
            if let Some(want) = want {
                assert_eq!(line, want);
            }
        }
        assert!(best >= Duration::from_millis(450) && best <= Duration::from_millis(1000), "the fastest run took {best:?}");
    }
}

// S22
#[test]
fn s22_a_refusal_is_a_stderr_line_and_exit_0() {
    let double = daemon(Daemon::Answers(Msg::Err { msg: "unknown terminal: t9".into() }));
    let out = run_against(&double, stop_input("Done."));

    assert_silent_success(&out, "refusal");
    assert!(out.one_stderr_line().contains("unknown terminal: t9"), "{}", out.stderr);
}

// S23
#[test]
fn s23_no_terminal_exits_at_once_without_reading_stdin() {
    for term_id in [None, Some("")] {
        let (best, outs) = fastest(5, || {
            let dir = sandbox();
            let mut cmd = hooks_cmd(&dir);
            if let Some(id) = term_id {
                cmd.env("TARMAC_TERM_ID", id);
            }
            Report::with_open_stdin(cmd.args(["run", "claude"]), Duration::from_secs(5)).expect("it exits")
        });

        for out in &outs {
            assert_silent_success(out, "no terminal");
            assert_no_connection(out, "no terminal");
        }
        assert!(best <= Duration::from_millis(200), "{term_id:?}: the fastest run took {best:?}");
    }
}

// S24
#[test]
fn s24_bad_input_exits_0_without_connecting() {
    for (input, case) in [
        (Vec::new(), "empty"),
        (b"not json".to_vec(), "not json"),
        (b"[]".to_vec(), "an array"),
        (br#"{"hook_event_name": 7}"#.to_vec(), "a number as the event"),
        (fixture("session-start"), "session start"),
        (br#"{"hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "waiting"}"#.to_vec(), "idle"),
        (stop_input_of_len((4 << 20) + 1), "over 4 MiB"),
    ] {
        let out = run_with_no_daemon(&["run", "claude"], input);

        assert_silent_success(&out, case);
        assert_no_connection(&out, case);
    }
}

// S24: the control of the limit case, so that one cannot pass on a parse failure.
#[test]
fn s24_an_input_of_exactly_4_mib_is_sent() {
    let out = run_with_no_daemon(&["run", "claude"], stop_input_of_len(4 << 20));

    assert_silent_success(&out, "4 MiB");
    assert!(out.stderr.contains(NO_DAEMON), "{}", out.stderr);
}

// S24
#[test]
fn s24_a_stdin_that_never_closes_ends_within_the_wait() {
    let dir = sandbox();
    let started = Instant::now();
    let out = Report::with_open_stdin(
        hooks_cmd(&dir).env("TARMAC_TERM_ID", "t9").args(["run", "claude"]),
        Duration::from_secs(5),
    )
    .expect("it exits");

    assert!(started.elapsed() <= Duration::from_millis(1500), "took {:?}", started.elapsed());
    assert_silent_success(&out, "open stdin");
    assert_no_connection(&out, "open stdin");
}

// S25
#[test]
fn s25_bad_arguments_exit_0_with_one_stderr_line() {
    for args in [&["run"][..], &["run", "codex"], &["run", "cursor"], &["run", "claude", "extra"]] {
        let out = run_with_no_daemon(args, stop_input("Done."));

        let case = format!("{args:?}");
        assert_silent_success(&out, &case);
        out.one_stderr_line();
        assert_no_connection(&out, &case);
    }
}

// ---- install, uninstall, status ----

const F_CLAUDE: &str = r#"{
  "permissions": {
    "allow": [
      "Bash(ls:*)",
      "Read(./notes/表.md)"
    ],
    "deny": []
  },
  "env": {
    "GREETING": "é"
  },
  "model": "opus",
  "cleanupPeriodDays": 30
}
"#;

const OWN_HOOKS: &str = r#"  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "say done"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre"
          }
        ]
      }
    ]
  }"#;

const BARE_STOP: &str = r#"    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "tarmac hooks run claude"
          }
        ]
      }
    ]"#;

const USER_EVENTS: &str = r#"    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo pre"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "echo post"
          }
        ]
      }
    ]"#;

/// F-claude with `hooks` (holding `inner`) as its last key.
fn f_claude_with_hooks_last(hooks: &str) -> String {
    F_CLAUDE.replace("  \"cleanupPeriodDays\": 30\n}", &format!("  \"cleanupPeriodDays\": 30,\n{hooks}\n}}"))
}

fn f_own_hooks() -> String {
    f_claude_with_hooks_last(OWN_HOOKS)
}

/// F-claude with `"hooks": { <inner> }` between `permissions` and `env`.
fn f_claude_with_hooks_mid(inner: &str) -> String {
    F_CLAUDE.replace("  },\n  \"env\"", &format!("  }},\n  \"hooks\": {{\n{inner}\n  }},\n  \"env\""))
}

fn f_mid() -> String {
    f_claude_with_hooks_mid(&format!("{BARE_STOP},\n{USER_EVENTS}"))
}

fn f_mid_only() -> String {
    f_claude_with_hooks_mid(BARE_STOP)
}

/// F-claude in a 4-space indent with no final newline.
fn f_4() -> String {
    let lines: Vec<String> = F_CLAUDE
        .lines()
        .map(|l| {
            let depth = l.len() - l.trim_start().len();
            format!("{}{}", " ".repeat(depth * 2), l.trim_start())
        })
        .collect();
    lines.join("\n")
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn json(path: &Path) -> serde_json::Value {
    serde_json::from_str(&read(path)).unwrap()
}

fn backup_of(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}.tarmac-backup", path.display()))
}

fn user_settings(dir: &Path) -> PathBuf {
    dir.join("home/.claude/settings.json")
}

fn project_settings(dir: &Path) -> PathBuf {
    dir.join("proj/.claude/settings.local.json")
}

fn put(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn hooks(dir: &Path, args: &[&str]) -> Report {
    Report::of(hooks_cmd(dir).args(args))
}

fn claude(dir: &Path, verb: &str) -> Report {
    hooks(dir, &[verb, "--target", "claude-code"])
}

/// Every file under `dir`, so a test can see that nothing new was made.
fn tree(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for entry in std::fs::read_dir(&d).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() && !path.is_symlink() {
                stack.push(path.clone());
            }
            found.push(path);
        }
    }
    found.sort();
    found
}

fn handler() -> serde_json::Value {
    serde_json::json!({"type": "command", "command": "tarmac hooks run claude || true", "timeout": 5})
}

fn four_groups() -> serde_json::Value {
    let group = serde_json::json!([{"hooks": [handler()]}]);
    serde_json::json!({"Notification": group, "Stop": group, "UserPromptSubmit": group, "SessionStart": group})
}

fn keys(v: &serde_json::Value) -> Vec<&str> {
    v.as_object().unwrap().keys().map(String::as_str).collect()
}

// S1
#[test]
fn s1_install_into_a_missing_file_makes_it() {
    let dir = sandbox();
    let path = user_settings(&dir);
    let out = claude(&dir, "install");

    assert_eq!((out.code(), out.stderr.as_str()), (Some(0), ""));
    assert_eq!(out.stdout, format!("installed: {}\n", path.display()));
    assert_eq!(json(&path), serde_json::json!({"hooks": four_groups()}));
    let text = read(&path);
    assert!(text.starts_with("{\n  \"hooks\": {\n    \"Notification\": [\n      {\n"), "{text}");
    assert!(text.ends_with("\n}\n"), "{text}");
    assert!(!backup_of(&path).exists());
}

// S2
#[test]
fn s2_install_merges_and_backs_the_file_up() {
    let dir = sandbox();
    let path = user_settings(&dir);
    put(&path, &f_own_hooks());
    let out = claude(&dir, "install");

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    let backup = backup_of(&path);
    assert_eq!(out.stdout, format!("installed: {}\nbackup: {}\n", path.display(), backup.display()));
    let v = json(&path);
    assert_eq!(keys(&v), ["permissions", "env", "model", "cleanupPeriodDays", "hooks"]);
    let own: serde_json::Value = serde_json::from_str(&format!("{{\n{OWN_HOOKS}\n}}")).unwrap();
    for key in ["permissions", "env", "model", "cleanupPeriodDays"] {
        assert_eq!(v[key], json(&backup)[key], "{key}");
    }
    assert_eq!(keys(&v["hooks"]), ["Stop", "PreToolUse", "Notification", "UserPromptSubmit", "SessionStart"]);
    assert_eq!(v["hooks"]["Stop"][0], own["hooks"]["Stop"][0]);
    assert_eq!(v["hooks"]["Stop"][1], serde_json::json!({"hooks": [handler()]}));
    assert_eq!(v["hooks"]["PreToolUse"], own["hooks"]["PreToolUse"]);
    assert_eq!(read(&backup), f_own_hooks());
}

fn mtime(path: &Path) -> std::time::SystemTime {
    std::fs::metadata(path).unwrap().modified().unwrap()
}

// S3
#[test]
fn s3_a_second_install_writes_nothing() {
    let dir = sandbox();
    let path = user_settings(&dir);
    let backup = backup_of(&path);
    put(&path, &f_own_hooks());
    claude(&dir, "install");
    let before = (read(&path), mtime(&path), read(&backup), mtime(&backup));
    std::thread::sleep(Duration::from_millis(20));

    let out = claude(&dir, "install");

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    assert_eq!(out.stdout, format!("already installed: {}\n", path.display()));
    assert_eq!((read(&path), mtime(&path), read(&backup), mtime(&backup)), before);
}

/// install then uninstall, from `original`, at user scope.
#[track_caller]
fn round_trip(original: &str) -> String {
    let dir = sandbox();
    let path = user_settings(&dir);
    put(&path, original);
    for verb in ["install", "uninstall"] {
        let out = claude(&dir, verb);
        assert_eq!(out.code(), Some(0), "{verb}: {}", out.stderr);
    }
    read(&path)
}

// S4
#[test]
fn s4_install_then_uninstall_gives_the_original_bytes_back() {
    for (name, original) in [("F-claude", F_CLAUDE.to_string()), ("F-own-hooks", f_own_hooks()), ("F-4", f_4())] {
        assert_eq!(round_trip(&original), original, "{name}");
    }
}

// Review answer 8: a settings.json that Claude Code 2.1.325 wrote itself.
#[test]
fn a_file_that_claude_wrote_comes_back_byte_for_byte() {
    let original = String::from_utf8(fixture("claude-written-settings")).unwrap();
    assert_eq!(round_trip(&original), original);
}

// S4b
#[test]
fn s4b_a_removal_moves_no_other_key() {
    let dir = sandbox();
    let path = user_settings(&dir);
    put(&path, &f_mid());
    assert_eq!(claude(&dir, "uninstall").code(), Some(0));
    assert_eq!(read(&path), f_claude_with_hooks_mid(USER_EVENTS));

    put(&path, &f_mid_only());
    assert_eq!(claude(&dir, "uninstall").code(), Some(0));
    assert_eq!(read(&path), F_CLAUDE);

    put(&path, &f_mid());
    assert_eq!(claude(&dir, "install").code(), Some(0));
    let v = json(&path);
    assert_eq!(keys(&v), ["permissions", "hooks", "env", "model", "cleanupPeriodDays"]);
    assert_eq!(
        keys(&v["hooks"]),
        ["PreToolUse", "PostToolUse", "Notification", "Stop", "UserPromptSubmit", "SessionStart"]
    );
}

/// A dir holding a `tarmac` that is a symlink to the binary under test.
fn path_with_this_binary(dir: &Path) -> PathBuf {
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::os::unix::fs::symlink(env!("CARGO_BIN_EXE_tarmac"), bin.join("tarmac")).unwrap();
    bin
}

fn status_line<'a>(out: &'a Report, prefix: &str) -> &'a str {
    out.stdout.lines().find(|l| l.starts_with(prefix)).unwrap_or_else(|| panic!("no `{prefix}` line: {}", out.stdout))
}

// S7
#[test]
fn s7_status_reads_both_scopes_and_the_path() {
    let dir = sandbox();
    claude(&dir, "install");
    put(&project_settings(&dir), &format!("{{\n  \"hooks\": {{\n{BARE_STOP}\n  }}\n}}\n"));
    std::fs::copy(user_settings(&dir), dir.join("proj/.claude/settings.json")).unwrap();
    let bin = path_with_this_binary(&dir);

    let out = Report::of(hooks_cmd(&dir).env("PATH", &bin).arg("status"));

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    let user = status_line(&out, "claude-code  user");
    assert!(user.contains(&user_settings(&dir).display().to_string()) && user.ends_with("  installed"), "{user}");
    let project = status_line(&out, "claude-code  project");
    assert!(project.contains(&project_settings(&dir).display().to_string()), "{project}");
    assert!(project.ends_with("installed, old form (run tarmac hooks install)"), "{project}");
    assert!(status_line(&out, "codex").ends_with("not supported yet"));
    assert_eq!(
        status_line(&out, "tarmac on PATH"),
        format!("tarmac on PATH: {} (this binary)", bin.join("tarmac").display())
    );
}

// S7
#[test]
fn s7_the_path_line_names_the_first_executable_tarmac() {
    let dir = sandbox();
    let empty = dir.join("empty");
    std::fs::create_dir_all(&empty).unwrap();
    let out = Report::of(hooks_cmd(&dir).env("PATH", &empty).arg("status"));
    assert_eq!(status_line(&out, "tarmac on PATH"), "tarmac on PATH: not found (the hooks will do nothing)");

    let (a, b) = (dir.join("a"), dir.join("b"));
    for (d, mode) in [(&a, 0o644), (&b, 0o755)] {
        std::fs::create_dir_all(d).unwrap();
        put(&d.join("tarmac"), "#!/bin/sh\nexit 0\n");
        std::fs::set_permissions(d.join("tarmac"), std::os::unix::fs::PermissionsExt::from_mode(mode)).unwrap();
    }
    let joined = std::env::join_paths([&a, &b]).unwrap();
    let out = Report::of(hooks_cmd(&dir).env("PATH", joined).arg("status"));
    assert_eq!(
        status_line(&out, "tarmac on PATH"),
        format!("tarmac on PATH: {} (another binary than this one)", b.join("tarmac").display())
    );
}

// S8
#[test]
fn s8_uninstall_removes_ours_only() {
    let dir = sandbox();
    let path = user_settings(&dir);
    put(&path, &f_own_hooks());
    claude(&dir, "install");
    let installed = read(&path);

    let out = claude(&dir, "uninstall");

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    assert_eq!(out.stdout, format!("uninstalled: {}\nbackup: {}\n", path.display(), backup_of(&path).display()));
    assert_eq!(read(&path), f_own_hooks());
    assert_eq!(read(&backup_of(&path)), installed);
}

// S9
#[test]
fn s9_uninstall_leaves_every_near_match_as_it_was() {
    let dir = sandbox();
    let path = user_settings(&dir);
    let foreign = serde_json::json!([
        {"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"},
        {"type": "command", "command": "tarmac hooks run claude --x"},
        {"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]},
        {"type": "command", "command": "tarmac hooks run claude", "args": []},
        {"type": "prompt", "command": "tarmac hooks run claude"},
        {"command": "tarmac hooks run claude"},
        "tarmac hooks run claude"
    ]);
    let mut all = vec![handler(), serde_json::json!({"type": "command", "command": "tarmac hooks run claude"}), serde_json::json!({"type": "command", "command": " tarmac hooks run claude "})];
    all.extend(foreign.as_array().unwrap().iter().cloned());
    put(&path, &serde_json::json!({"hooks": {"Stop": [{"hooks": all}]}}).to_string());

    let out = claude(&dir, "uninstall");

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    assert_eq!(json(&path), serde_json::json!({"hooks": {"Stop": [{"hooks": foreign}]}}));
}

// S10
#[test]
fn s10_an_old_form_shows_in_status_and_install_replaces_it() {
    let bare = serde_json::json!({"type": "command", "command": "tarmac hooks run claude"});
    let current = serde_json::json!({"hooks": four_groups()});
    let with = |f: &dyn Fn(&mut serde_json::Value)| {
        let mut v = current.clone();
        f(&mut v);
        v
    };
    let forms = [
        ("a", serde_json::json!({"hooks": {"Notification": [{"hooks": [bare]}], "Stop": [{"hooks": [bare]}], "UserPromptSubmit": [{"hooks": [bare]}], "SessionStart": [{"hooks": [bare]}]}})),
        ("b", with(&|v| { v["hooks"].as_object_mut().unwrap().shift_remove("SessionStart"); })),
        ("c", with(&|v| v["hooks"]["Stop"].as_array_mut().unwrap().push(serde_json::json!({"hooks": [handler()]})))),
        ("d", with(&|v| v["hooks"]["Stop"] = serde_json::json!([{"hooks": [{"type": "command", "command": "say done"}, handler()]}]))),
        ("e", with(&|v| v["hooks"]["Notification"][0]["matcher"] = serde_json::json!("permission_prompt"))),
        ("f", with(&|v| v["hooks"]["PreToolUse"] = serde_json::json!([{"hooks": [handler()]}]))),
    ];
    for (name, form) in forms {
        let dir = sandbox();
        put(&user_settings(&dir), &serde_json::to_string_pretty(&form).unwrap());
        let status = hooks(&dir, &["status"]);
        assert!(status_line(&status, "claude-code  user").ends_with("installed, old form (run tarmac hooks install)"), "({name}) {}", status.stdout);

        assert_eq!(claude(&dir, "install").code(), Some(0), "({name})");

        let status = hooks(&dir, &["status"]);
        assert!(status_line(&status, "claude-code  user").ends_with("  installed"), "({name}) {}", status.stdout);
        let v = json(&user_settings(&dir));
        let ours = v["hooks"].as_object().unwrap().values().flat_map(|g| g.as_array().unwrap())
            .flat_map(|g| g["hooks"].as_array().unwrap()).filter(|h| h["command"].as_str().is_some_and(|c| c.contains("tarmac"))).count();
        assert_eq!(ours, 4, "({name}) {v}");
        if name == "d" {
            assert_eq!(v["hooks"]["Stop"][0], serde_json::json!({"hooks": [{"type": "command", "command": "say done"}]}));
        }
    }
}

// S12
#[test]
fn s12_codex_is_skipped_as_a_success() {
    const SKIP: &str = "skipped codex: hooks are not supported for codex yet\n";
    for verb in ["install", "uninstall"] {
        let dir = sandbox();
        let out = hooks(&dir, &[verb, "--target", "codex"]);
        assert_eq!((out.code(), out.stdout.as_str(), out.stderr.as_str()), (Some(0), SKIP, ""), "{verb}");
        assert_eq!(tree(&dir.join("home")), Vec::<PathBuf>::new(), "{verb}");
    }

    let dir = sandbox();
    let out = hooks(&dir, &["install"]);
    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    assert_eq!(out.stdout, format!("installed: {}\n{SKIP}", user_settings(&dir).display()));
}

// S13
#[test]
fn s13_claude_config_dir_and_project_scope_pick_the_file() {
    let dir = sandbox();
    let cfg = dir.join("cfg");
    let out = Report::of(hooks_cmd(&dir).env("CLAUDE_CONFIG_DIR", &cfg).args(["install", "--target", "claude-code"]));
    assert_eq!(out.stdout, format!("installed: {}\n", cfg.join("settings.json").display()));
    assert_eq!(json(&cfg.join("settings.json")), serde_json::json!({"hooks": four_groups()}));
    assert_eq!(tree(&dir.join("home")), Vec::<PathBuf>::new());

    for config_dir in [Some(cfg.as_path()), None] {
        let dir = sandbox();
        let local = project_settings(&dir);
        let shared = dir.join("proj/.claude/settings.json");
        put(&shared, F_CLAUDE);
        put(&local, F_CLAUDE);
        let mut cmd = hooks_cmd(&dir);
        if let Some(cfg) = config_dir {
            cmd.env("CLAUDE_CONFIG_DIR", cfg);
        }
        let out = Report::of(cmd.args(["install", "--target", "claude-code", "--scope", "project"]));

        assert_eq!(out.code(), Some(0), "{}", out.stderr);
        let backup = backup_of(&local);
        let mut lines = out.stdout.lines();
        assert_eq!(lines.next(), Some(format!("installed: {}", local.display()).as_str()));
        assert_eq!(lines.next(), Some(format!("backup: {}", backup.display()).as_str()));
        let hint = lines.next().unwrap_or_default();
        assert!(hint.starts_with("hint: ") && hint.contains(&local.display().to_string()) && hint.contains(&backup.display().to_string()), "{hint}");
        assert_eq!(json(&local)["hooks"], four_groups());
        assert_eq!(read(&shared), F_CLAUDE);
    }
}

// S13
#[test]
fn s13_an_empty_claude_config_dir_is_home() {
    let dir = sandbox();
    let out = claude(&dir, "install");
    assert_eq!(out.stdout, format!("installed: {}\n", user_settings(&dir).display()));
}

// S14
#[test]
fn s14_dry_run_writes_nothing() {
    let dir = sandbox();
    let before = tree(&dir);
    let path = user_settings(&dir);
    for (verb, want) in [("install", "would install"), ("uninstall", "not installed")] {
        let out = hooks(&dir, &[verb, "--target", "claude-code", "--dry-run"]);
        assert_eq!((out.code(), out.stdout.clone()), (Some(0), format!("{want}: {}\n", path.display())), "{verb}");
    }
    assert_eq!(tree(&dir), before);

    put(&path, &f_own_hooks());
    claude(&dir, "install");
    let before = tree(&dir);
    let bytes = read(&path);
    for (verb, want) in [("install", "already installed"), ("uninstall", "would uninstall")] {
        let out = hooks(&dir, &[verb, "--target", "claude-code", "--dry-run"]);
        assert_eq!((out.code(), out.stdout.clone()), (Some(0), format!("{want}: {}\n", path.display())), "{verb}");
    }
    assert_eq!((tree(&dir), read(&path)), (before, bytes));

    put(&path, "{\"a\": 1,}");
    for verb in ["install", "uninstall"] {
        assert_eq!(hooks(&dir, &[verb, "--target", "claude-code", "--dry-run"]).code(), Some(1), "{verb}");
    }
}

// S15
#[test]
fn s15_a_symlinked_file_is_written_through() {
    let dir = sandbox();
    let target = dir.join("dotfiles/claude-settings.json");
    let link = user_settings(&dir);
    put(&target, F_CLAUDE);
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&target, &link).unwrap();

    let out = claude(&dir, "install");

    assert_eq!(out.code(), Some(0), "{}", out.stderr);
    let backup = backup_of(&target);
    assert_eq!(out.stdout, format!("installed: {}\nbackup: {}\n", link.display(), backup.display()));
    assert_eq!(std::fs::read_link(&link).unwrap(), target);
    assert_eq!(json(&target)["hooks"], four_groups());
    assert_eq!(read(&backup), F_CLAUDE);
}

// S15
#[test]
fn s15_a_symlink_to_a_missing_file_is_refused() {
    let dir = sandbox();
    let link = user_settings(&dir);
    std::fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(dir.join("dotfiles/missing.json"), &link).unwrap();
    let before = tree(&dir);

    let out = claude(&dir, "install");

    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().contains(&link.display().to_string()), "{}", out.stderr);
    assert_eq!(tree(&dir), before);
}

fn mode(path: &Path) -> u32 {
    std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(path).unwrap().permissions()) & 0o7777
}

fn set_mode(path: &Path, mode: u32) {
    std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(mode)).unwrap();
}

// S16
#[test]
fn s16_the_files_mode_is_kept_and_a_new_file_gets_the_default() {
    let dir = sandbox();
    let path = user_settings(&dir);
    put(&path, F_CLAUDE);
    set_mode(&path, 0o600);
    claude(&dir, "install");
    assert_eq!((mode(&path), mode(&backup_of(&path))), (0o600, 0o600));

    let dir = sandbox();
    let reference = dir.join("reference");
    std::fs::File::create(&reference).unwrap();
    claude(&dir, "install");
    assert_eq!(mode(&user_settings(&dir)), mode(&reference));
}

// S16b
#[test]
fn s16b_a_target_that_is_not_writable_fails_closed() {
    let probe = sandbox().join("probe");
    std::fs::write(&probe, "").unwrap();
    set_mode(&probe, 0o444);
    if std::fs::OpenOptions::new().write(true).open(&probe).is_ok() {
        eprintln!("skipped: this user can write a 0444 file (root?)");
        return;
    }
    for (case, file_mode, dir_mode) in [("a 0444 file", 0o444, 0o755), ("a 0555 dir", 0o644, 0o555)] {
        let dir = sandbox();
        let path = user_settings(&dir);
        let parent = path.parent().unwrap().to_path_buf();
        put(&path, F_CLAUDE);
        set_mode(&path, file_mode);
        set_mode(&parent, dir_mode);
        let before = tree(&parent);

        let out = claude(&dir, "install");

        set_mode(&parent, 0o755);
        assert_eq!(out.code(), Some(1), "{case}");
        assert!(out.one_stderr_line().contains(&path.display().to_string()), "{case}: {}", out.stderr);
        assert_eq!((read(&path), mode(&path)), (F_CLAUDE.to_string(), file_mode), "{case}");
        assert_eq!(tree(&parent), before, "{case}");
    }
}

// S26
#[test]
fn s26_a_file_of_the_wrong_shape_is_refused() {
    for bad in [
        r#"{"a": 1,}"#,
        "[]",
        r#"{"hooks": []}"#,
        r#"{"hooks": {"Stop": {}}}"#,
        r#"{"hooks": {"Stop": [1]}}"#,
        r#"{"hooks": {"Stop": [{"hooks": {}}]}}"#,
        "",
        "\u{feff}{}",
    ] {
        for verb in ["install", "uninstall"] {
            let dir = sandbox();
            let path = user_settings(&dir);
            put(&path, bad);
            let before = tree(&dir);

            let out = claude(&dir, verb);

            assert_eq!(out.code(), Some(1), "{verb} {bad:?}");
            assert!(out.one_stderr_line().contains(&path.display().to_string()), "{verb} {bad:?}: {}", out.stderr);
            assert_eq!((read(&path), tree(&dir)), (bad.to_string(), before), "{verb} {bad:?}");
        }
    }
}

// S26
#[test]
fn s26_status_shows_an_unparsable_file_and_exits_1() {
    let dir = sandbox();
    put(&user_settings(&dir), r#"{"a": 1,}"#);
    let out = hooks(&dir, &["status"]);
    assert_eq!(out.code(), Some(1));
    assert!(status_line(&out, "claude-code  user").contains("unreadable: "), "{}", out.stdout);
}

// Review answer 7: an empty file, or one with a BOM, names its cause.
#[test]
fn an_empty_file_or_a_bom_is_named_as_the_cause() {
    for (bad, cause) in [("", "empty"), ("\u{feff}{}", "BOM")] {
        let dir = sandbox();
        put(&user_settings(&dir), bad);
        let out = claude(&dir, "install");
        assert!(out.stderr.contains(cause), "{bad:?}: {}", out.stderr);
    }
}

// S27
#[test]
fn s27_a_refused_target_does_not_stop_the_other() {
    let dir = sandbox();
    put(&user_settings(&dir), r#"{"a": 1,}"#);
    let out = hooks(&dir, &["install"]);
    assert_eq!(out.code(), Some(1));
    assert_eq!(out.stdout, "skipped codex: hooks are not supported for codex yet\n");
}

// S28
#[test]
fn s28_a_usage_error_exits_2_and_makes_no_file() {
    for args in [
        &[][..],
        &["frob"],
        &["install", "--target", "cursor"],
        &["install", "--scope", "system"],
        &["install", "extra"],
        &["uninstall", "--target"],
        &["status", "--x"],
    ] {
        let dir = sandbox();
        let out = hooks(&dir, args);

        assert_eq!(out.code(), Some(2), "{args:?}");
        assert!(out.stderr.contains("usage"), "{args:?}: {}", out.stderr);
        assert_eq!(tree(&dir), [dir.join("home"), dir.join("proj")], "{args:?}");
    }
}
