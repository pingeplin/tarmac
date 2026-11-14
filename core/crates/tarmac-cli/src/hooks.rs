//! `tarmac hooks`: Claude Code reports through one fixed hook entry (spec
//! 2611.0010). The settings file holds only a call to `tarmac hooks run claude`;
//! the mapping from a hook's input to a report lives here, so an upgrade of the
//! binary updates it. Only the cli knows an agent: the daemon gets a plain
//! `report`.

use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use serde::{Deserialize, Deserializer};
use serde_json::{Map, Value, json};
use tarmac_protocol::{Msg, REPORT_TEXT_MAX, cap_report_text};

use crate::agents::{Env, Scope, Target, parse_flags};
use crate::report;
use crate::settings_file::{self, SettingsFile};

const COMMAND: &str = "tarmac hooks run claude || true";
/// The design's unguarded form, which a user may write by hand.
const BARE_COMMAND: &str = "tarmac hooks run claude";
const EVENTS: [&str; 4] = ["Notification", "Stop", "UserPromptSubmit", "SessionStart"];

fn current_handler() -> Value {
    json!({"type": "command", "command": COMMAND, "timeout": 5})
}

const USAGE: &str = "usage: tarmac hooks install|uninstall [--target claude-code|codex|all] [--scope user|project] [--dry-run]  |  tarmac hooks status  |  tarmac hooks run <agent>";

const HOOK_STDIN_MAX: usize = 4 << 20;
const HOOK_STDIN_WAIT: Duration = Duration::from_secs(1);
/// From connect to `ack`. An older daemon never answers `report`, and each
/// hook would otherwise hold Claude for the 5 s of the other verbs.
const HOOK_DEADLINE: Duration = Duration::from_millis(500);

const SKIPPED_CODEX: &str = "skipped codex: hooks are not supported for codex yet";
const OLD_FORM: &str = "installed, old form (run tarmac hooks install)";

pub fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        Some("run") => run_hook(&args[1..]),
        Some("install") => change(Verb::Install, &args[1..]),
        Some("uninstall") => change(Verb::Uninstall, &args[1..]),
        Some("status") if args.len() == 1 => status(),
        _ => {
            eprintln!("tarmac: {USAGE}");
            2
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Verb {
    Install,
    Uninstall,
}

/// Every target is tried, so the exit code is the aggregate: 1 when any
/// target was refused.
fn change(verb: Verb, args: &[String]) -> i32 {
    let flags = match parse_flags(args) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("tarmac: {e}\n{USAGE}");
            return 2;
        }
    };
    let Some(env) = Env::from_process() else { return 1 };
    let mut failed = false;
    for target in flags.targets {
        match target {
            Target::ClaudeCode => {
                let path = claude_settings_path(flags.scope, &env);
                match apply(verb, &path, flags.scope, flags.dry_run) {
                    Ok(lines) => lines.iter().for_each(|line| println!("{line}")),
                    Err(why) => {
                        eprintln!("tarmac: {}: {why}", path.display());
                        failed = true;
                    }
                }
            }
            Target::Codex => println!("{SKIPPED_CODEX}"),
        }
    }
    i32::from(failed)
}

/// Claude's settings file for `scope`. Project scope is the personal
/// `settings.local.json`, never the shared `settings.json`.
fn claude_settings_path(scope: Scope, env: &Env) -> PathBuf {
    match scope {
        Scope::User => Target::ClaudeCode.user_root(env).join("settings.json"),
        Scope::Project => env.cwd.join(".claude/settings.local.json"),
    }
}

/// The result lines of one install or uninstall of `path`.
fn apply(verb: Verb, path: &Path, scope: Scope, dry_run: bool) -> Result<Vec<String>, String> {
    let mut file = load(path)?;
    let shown = path.display();
    match verb {
        Verb::Install if is_current(&file.root) => return Ok(vec![format!("already installed: {shown}")]),
        Verb::Install if dry_run => return Ok(vec![format!("would install: {shown}")]),
        Verb::Install => {
            remove_ours(&mut file.root);
            add_current(&mut file.root);
        }
        Verb::Uninstall if file.original.is_none() || !remove_ours(&mut file.root) => {
            return Ok(vec![format!("not installed: {shown}")]);
        }
        Verb::Uninstall if dry_run => return Ok(vec![format!("would uninstall: {shown}")]),
        Verb::Uninstall => {}
    }
    let backup = settings_file::write(&file)?;
    let done = if verb == Verb::Install { "installed" } else { "uninstalled" };
    let mut lines = vec![format!("{done}: {shown}")];
    lines.extend(backup.iter().map(|b| format!("backup: {}", b.display())));
    if scope == Scope::Project {
        lines.push(format!(
            "hint: git ignores {real} only if you add it to .gitignore (Claude does this only for a file it made); the same holds for {backup}",
            real = file.real.display(),
            backup = settings_file::backup_path(&file.real).display(),
        ));
    }
    Ok(lines)
}

/// The settings file, refused when a type that a merge relies on is wrong, so
/// that `--dry-run` and `status` see the same refusal as a write.
fn load(path: &Path) -> Result<SettingsFile, String> {
    let file = settings_file::load(path)?;
    check_shape(&file.root)?;
    Ok(file)
}

/// The types that a merge relies on. A handler that is not an object is the
/// user's, and is left as it is.
fn check_shape(root: &Value) -> Result<(), String> {
    let root = root.as_object().ok_or("the top level is not an object")?;
    let Some(hooks) = root.get("hooks") else { return Ok(()) };
    let hooks = hooks.as_object().ok_or("`hooks` is not an object")?;
    for (event, groups) in hooks {
        let groups = groups.as_array().ok_or_else(|| format!("`hooks.{event}` is not an array"))?;
        for group in groups {
            let group = group.as_object().ok_or_else(|| format!("a group in `hooks.{event}` is not an object"))?;
            if group.get("hooks").is_some_and(|h| !h.is_array()) {
                return Err(format!("the `hooks` of a group in `hooks.{event}` is not an array"));
            }
        }
    }
    Ok(())
}

/// Exit 1 when a file is unreadable; `not installed` is not an error.
fn status() -> i32 {
    let Some(env) = Env::from_process() else { return 1 };
    let mut unreadable = false;
    let mut rows = Vec::new();
    for (scope, name) in [(Scope::User, "user"), (Scope::Project, "project")] {
        let path = claude_settings_path(scope, &env);
        let state = match load(&path) {
            Ok(f) if is_current(&f.root) => "installed".to_string(),
            Ok(f) if ours(&f.root).next().is_some() => OLD_FORM.to_string(),
            Ok(_) => "not installed".to_string(),
            Err(why) => {
                unreadable = true;
                format!("unreadable: {why}")
            }
        };
        rows.push(("claude-code", name, path.display().to_string(), state));
    }
    rows.push(("codex", "-", "-".into(), "not supported yet".into()));
    let width = rows.iter().map(|r| r.2.chars().count()).max().unwrap_or(0);
    for (agent, scope, path, state) in &rows {
        println!("{agent:<11}  {scope:<7}  {path:<width$}  {state}");
    }
    println!("tarmac on PATH: {}", path_tarmac());
    i32::from(unreadable)
}

/// The first `tarmac` on this process's `PATH` that runs. A hook sees
/// `claude`'s `PATH`, which is this one only when both started from the same
/// shell.
fn path_tarmac() -> String {
    let path = std::env::var_os("PATH");
    let runs = |c: &PathBuf| std::fs::metadata(c).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0);
    let Some(found) = path.iter().flat_map(std::env::split_paths).map(|dir| dir.join("tarmac")).find(runs) else {
        return "not found (the hooks will do nothing)".into();
    };
    let this = std::env::current_exe().and_then(std::fs::canonicalize).ok();
    let same = this.is_some() && std::fs::canonicalize(&found).ok() == this;
    format!("{} ({})", found.display(), if same { "this binary" } else { "another binary than this one" })
}

/// Always 0, and never a byte on stdout: Claude adds a hook's stdout to the
/// model's context on `UserPromptSubmit` and `SessionStart`, and a non-zero
/// exit can block a prompt or continue a turn. Claude never shows the stderr
/// of an exit 0, so the reason goes there.
fn run_hook(args: &[String]) -> i32 {
    let outcome = std::panic::catch_unwind(|| hook(args)).unwrap_or_else(|_| Err("panicked".into()));
    if let Err(why) = outcome {
        let _ = writeln!(io::stderr(), "tarmac: hooks run: {why}");
    }
    0
}

fn hook(args: &[String]) -> Result<(), String> {
    match args {
        [agent] if agent == "claude" => {}
        [agent] => return Err(format!("unknown agent '{agent}' (claude)")),
        _ => return Err("usage: tarmac hooks run <agent>".into()),
    }
    // Outside a Tarmac terminal every hook ends here, before a read of stdin.
    let Some(term_id) = crate::env_override("TARMAC_TERM_ID") else { return Ok(()) };
    if io::stdin().is_terminal() {
        return Ok(());
    }
    let input: ClaudeInput =
        serde_json::from_slice(&read_input()?).map_err(|e| format!("the input is not a JSON object: {e}"))?;
    let Some(msg) = claude_report(&term_id.to_string_lossy(), &input) else { return Ok(()) };
    let no_answer = format!("no answer from the daemon in {} ms", HOOK_DEADLINE.as_millis());
    report::send(&msg, HOOK_DEADLINE, &no_answer)
}

/// Stdin, read on a thread of its own so that a writer that never closes it
/// costs `HOOK_STDIN_WAIT` at most.
fn read_input() -> Result<Vec<u8>, String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut input = Vec::new();
        let read = io::stdin().lock().take(HOOK_STDIN_MAX as u64 + 1).read_to_end(&mut input);
        let _ = tx.send(read.map(|_| input));
    });
    match rx.recv_timeout(HOOK_STDIN_WAIT) {
        Ok(Ok(input)) if input.len() <= HOOK_STDIN_MAX => Ok(input),
        Ok(Ok(_)) => Err(format!("the input is over {HOOK_STDIN_MAX} bytes")),
        Ok(Err(e)) => Err(format!("cannot read the input: {e}")),
        Err(_) => Err(format!("the input did not end in {} s", HOOK_STDIN_WAIT.as_secs())),
    }
}

/// The four fields of a Claude hook input that the mapping reads; the rest,
/// a long `prompt` among them, is skipped unparsed.
#[derive(Deserialize, Default)]
#[serde(default)]
struct ClaudeInput {
    hook_event_name: Lenient,
    notification_type: Lenient,
    message: Lenient,
    last_assistant_message: Lenient,
}

/// A field that counts only when it is a string; any other value is as if
/// the field were absent.
#[derive(Default)]
struct Lenient(Option<String>);

impl<'de> Deserialize<'de> for Lenient {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Lenient(match Value::deserialize(d)? {
            Value::String(s) => Some(s),
            _ => None,
        }))
    }
}

/// The report a Claude hook input stands for, if any. `SessionStart` is
/// installed but maps to nothing until slice 4.
fn claude_report(term_id: &str, input: &ClaudeInput) -> Option<Msg> {
    let report = |kind: &str, text: Option<String>| Some(Msg::Report { term_id: term_id.into(), kind: kind.into(), text });
    let text = |field: &Lenient| field.0.as_deref().and_then(report_text);
    match input.hook_event_name.0.as_deref()? {
        "Notification" if input.notification_type.0.as_deref() == Some("permission_prompt") => {
            report("blocked", text(&input.message))
        }
        "Stop" => report("done", text(&input.last_assistant_message)),
        "UserPromptSubmit" => report("clear", None),
        _ => None,
    }
}

/// The text without its control characters, its whitespace runs folded to one
/// space, trimmed and capped, in one pass that stops once the cap is passed.
/// Removal comes first so that `"a \u{1b} b"` folds to `"a b"`.
fn report_text(raw: &str) -> Option<String> {
    let mut text = String::new();
    let mut count = 0;
    let mut gap = false;
    for c in raw.chars().filter(|c| !c.is_control() || c.is_whitespace()) {
        if c.is_whitespace() {
            gap = count > 0;
            continue;
        }
        if gap {
            text.push(' ');
            count += 1;
            gap = false;
        }
        text.push(c);
        count += 1;
        if count > REPORT_TEXT_MAX {
            break;
        }
    }
    (count > 0).then(|| cap_report_text(&text))
}

/// Whether `handler` is one that `install` wrote, or the design's bare form.
/// Anything close to it is the user's: another path, other arguments, exec form.
fn is_ours(handler: &Value) -> bool {
    let Some(h) = handler.as_object() else { return false };
    h.get("type").and_then(Value::as_str) == Some("command")
        && !h.contains_key("args")
        && h.get("command").and_then(Value::as_str).is_some_and(|c| [COMMAND, BARE_COMMAND].contains(&c.trim()))
}

fn groups(root: &Value) -> impl Iterator<Item = (&String, &Value)> {
    root.get("hooks").and_then(Value::as_object).into_iter().flatten().flat_map(|(event, groups)| {
        groups.as_array().into_iter().flatten().map(move |group| (event, group))
    })
}

fn ours(root: &Value) -> impl Iterator<Item = &Value> {
    groups(root)
        .flat_map(|(_, group)| group.get("hooks").and_then(Value::as_array).into_iter().flatten())
        .filter(|h| is_ours(h))
}

/// Whether the handlers that are ours are exactly the current four: one alone
/// in a group with no other key under each event.
fn is_current(root: &Value) -> bool {
    let current_group = json!({"hooks": [current_handler()]});
    ours(root).count() == EVENTS.len()
        && EVENTS.iter().all(|event| {
            groups(root).filter(|(e, group)| e == event && **group == current_group).count() == 1
        })
}

/// Removes every handler of ours, and prunes only what that emptied: a
/// container that was already empty stays. `retain` and `shift_remove` keep
/// the order of every key that stays. Whether any was removed.
fn remove_ours(root: &mut Value) -> bool {
    let Some(root) = root.as_object_mut() else { return false };
    let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) else { return false };
    let mut removed = false;
    hooks.retain(|_, groups| {
        let Some(groups) = groups.as_array_mut() else { return true };
        let had = groups.len();
        groups.retain_mut(|group| {
            let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else { return true };
            let before = handlers.len();
            handlers.retain(|h| !is_ours(h));
            removed |= handlers.len() < before;
            handlers.len() == before || !handlers.is_empty()
        });
        had == 0 || !groups.is_empty()
    });
    if removed && hooks.is_empty() {
        root.shift_remove("hooks");
    }
    removed
}

/// Appends one group with the current handler to each of the four events; a
/// missing key is added at the end of its object.
fn add_current(root: &mut Value) {
    let Some(root) = root.as_object_mut() else { return };
    let hooks = root.entry("hooks").or_insert_with(|| Value::Object(Map::new()));
    let Some(hooks) = hooks.as_object_mut() else { return };
    for event in EVENTS {
        if let Some(groups) = hooks.entry(event).or_insert_with(|| json!([])).as_array_mut() {
            groups.push(json!({"hooks": [current_handler()]}));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings_file::render;

    fn fixture(name: &str) -> Value {
        let path = format!("{}/tests/fixtures/hooks/{name}.json", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    fn stop(message: Value) -> Value {
        json!({"hook_event_name": "Stop", "last_assistant_message": message})
    }

    fn report_of(input: Value) -> Option<Msg> {
        claude_report("t9", &serde_json::from_value(input).unwrap())
    }

    fn msg(kind: &str, text: Option<&str>) -> Msg {
        Msg::Report { term_id: "t9".into(), kind: kind.into(), text: text.map(str::to_string) }
    }

    fn done_text(message: Value) -> Option<String> {
        match report_of(stop(message)) {
            Some(Msg::Report { kind, text, .. }) if kind == "done" => text,
            other => panic!("a Stop is done, got {other:?}"),
        }
    }

    fn installed() -> Value {
        let mut root = json!({});
        add_current(&mut root);
        root
    }

    #[test]
    fn s5_a_permission_notification_is_blocked_with_its_message() {
        let input = json!({
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        });
        assert_eq!(report_of(input.clone()), Some(msg("blocked", Some("Claude needs your permission to use Bash"))));
    }

    // The inputs that Claude Code 2.1.325 sent.
    #[test]
    fn s5_the_captured_inputs_map_as_the_table_says() {
        assert_eq!(
            report_of(fixture("notification-permission")),
            Some(msg("blocked", Some("Claude needs your permission")))
        );
        assert_eq!(report_of(fixture("stop")), Some(msg("done", Some("You picked red."))));
        assert_eq!(report_of(fixture("user-prompt-submit")), Some(msg("clear", None)));
        assert_eq!(report_of(fixture("session-start")), None);
    }

    // Claude Code 2.1.325 sends AskUserQuestion and plan approval as a
    // permission prompt, so they are blocked too.
    #[test]
    fn a_question_and_a_plan_approval_arrive_as_permission_prompts() {
        assert_eq!(
            report_of(fixture("notification-ask-user-question")),
            Some(msg("blocked", Some("Claude needs your permission")))
        );
        assert_eq!(
            report_of(fixture("notification-plan-approval")),
            Some(msg("blocked", Some("Claude Code needs your approval for the plan")))
        );
    }

    #[test]
    fn s5_stop_is_done_with_its_text_folded() {
        assert_eq!(done_text(json!("Done.\n\n  All   tests pass.\n")), Some("Done. All tests pass.".into()));
    }

    #[test]
    fn s5_a_prompt_clears_and_a_session_start_is_nothing() {
        let prompt = json!({"hook_event_name": "UserPromptSubmit", "prompt": "x".repeat(10_000)});
        assert_eq!(report_of(prompt), Some(msg("clear", None)));
        assert_eq!(report_of(json!({"hook_event_name": "SessionStart", "source": "startup"})), None);
    }

    // The idle notification that Claude Code 2.1.325 sent 60 s after a Stop.
    #[test]
    fn s19_the_captured_idle_notification_is_nothing() {
        assert_eq!(fixture("notification-idle")["notification_type"], "idle_prompt");
        assert_eq!(report_of(fixture("notification-idle")), None);
    }

    #[test]
    fn s19_other_notifications_are_nothing() {
        for kind in [json!("idle_prompt"), json!("elicitation_dialog"), Value::Null] {
            let mut input = json!({"hook_event_name": "Notification", "message": "Claude is waiting for your input"});
            if !kind.is_null() {
                input["notification_type"] = kind.clone();
            }
            assert_eq!(report_of(input.clone()), None, "{kind}");
        }
    }

    #[test]
    fn an_unknown_or_missing_event_is_nothing() {
        for input in [json!({"hook_event_name": "PreToolUse"}), json!({"hook_event_name": 7}), json!({}), json!([])] {
            assert_eq!(report_of(input.clone()), None, "{input}");
        }
    }

    #[test]
    fn s18_a_long_text_is_capped_to_280_chars() {
        let text = done_text(json!("a".repeat(400))).unwrap();
        assert_eq!(text.chars().count(), REPORT_TEXT_MAX);
        assert!(text.ends_with('…'));
    }

    #[test]
    fn s18_no_text_when_it_is_blank_or_not_a_string() {
        for message in [json!(" \n\t "), json!(""), json!(7)] {
            assert_eq!(done_text(message.clone()), None, "{message}");
        }
        assert_eq!(report_of(json!({"hook_event_name": "Stop"})), Some(msg("done", None)));
    }

    #[test]
    fn s18_the_ends_are_trimmed() {
        assert_eq!(done_text(json!(" \n\t Done. \n")), Some("Done.".into()));
    }

    #[test]
    fn s18_every_kind_of_whitespace_folds() {
        assert_eq!(done_text(json!("a\t\r\n\u{000b}\u{000c}b")), Some("a b".into()));
    }

    #[test]
    fn s18_control_characters_are_removed_and_nothing_else_changes() {
        assert_eq!(done_text(json!("a\u{001b}[31mb\u{0007}c\u{009b}d")), Some("a[31mbcd".into()));
        assert_eq!(done_text(json!("a \u{001b} b")), Some("a b".into()));
        assert_eq!(done_text(json!("\u{001b}\u{0007}")), None);
    }

    #[test]
    fn s18_the_cap_counts_the_text_after_the_fold() {
        let text = format!("a{}", "   \n b".repeat(200));
        let folded = format!("a{}", " b".repeat(200));
        assert_eq!(done_text(json!(text)), Some(tarmac_protocol::cap_report_text(&folded)));
        assert_eq!(done_text(json!(text)).unwrap().chars().count(), REPORT_TEXT_MAX);
    }

    #[test]
    fn s18_unicode_whitespace_folds_and_is_not_removed() {
        assert_eq!(done_text(json!("a\u{000b}b\u{000c}c\u{0085}d\u{00a0}e")), Some("a b c d e".into()));
    }

    #[test]
    fn s18_the_cap_counts_the_text_after_removal() {
        let letters = "a".repeat(REPORT_TEXT_MAX);
        let with_esc = format!("{}\u{001b}{}", &letters[..140], &letters[140..]);
        assert_eq!(done_text(json!(with_esc)), Some(letters));
    }

    #[test]
    fn s9_ours_is_an_exact_command_on_a_command_handler_with_no_args() {
        let ours = [current_handler(), json!({"type": "command", "command": BARE_COMMAND}), json!({"type": "command", "command": " tarmac hooks run claude "})];
        let foreign = [
            json!({"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"}),
            json!({"type": "command", "command": "tarmac hooks run claude --x"}),
            json!({"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]}),
            json!({"type": "command", "command": BARE_COMMAND, "args": []}),
            json!({"type": "prompt", "command": BARE_COMMAND}),
            json!({"command": BARE_COMMAND}),
            json!(BARE_COMMAND),
        ];
        for h in &ours {
            assert!(is_ours(h), "{h}");
        }
        for h in &foreign {
            assert!(!is_ours(h), "{h}");
        }
    }

    #[test]
    fn s9_a_removal_keeps_every_foreign_handler_in_its_order() {
        let foreign = vec![
            json!({"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"}),
            json!({"type": "command", "command": "tarmac hooks run claude --x"}),
            json!({"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]}),
            json!({"type": "command", "command": BARE_COMMAND, "args": []}),
            json!({"type": "prompt", "command": BARE_COMMAND}),
            json!({"command": BARE_COMMAND}),
            json!(BARE_COMMAND),
        ];
        let mut all = vec![current_handler(), json!({"type": "command", "command": BARE_COMMAND}), json!({"type": "command", "command": " tarmac hooks run claude "})];
        all.extend(foreign.iter().cloned());
        let mut root = json!({"hooks": {"Stop": [{"hooks": all}]}});

        assert!(remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": [{"hooks": foreign}]}}));
    }

    #[test]
    fn the_installed_form_is_current() {
        let root = installed();
        assert!(is_current(&root));
        let hooks = root["hooks"].as_object().unwrap();
        let events = ["Notification", "Stop", "UserPromptSubmit", "SessionStart"];
        assert_eq!(hooks.keys().collect::<Vec<_>>(), events.iter().collect::<Vec<_>>());
        for event in events {
            assert_eq!(hooks[event], json!([{"hooks": [current_handler()]}]), "{event}");
        }
        let text = render(&root, None);
        assert!(text.contains(r#""type": "command",
            "command": "tarmac hooks run claude || true",
            "timeout": 5"#), "{text}");
    }

    fn old_forms() -> Vec<(&'static str, Value)> {
        let bare = json!({"type": "command", "command": BARE_COMMAND});
        let mut b = installed();
        b["hooks"].as_object_mut().unwrap().shift_remove("SessionStart");
        let mut c = installed();
        c["hooks"]["Stop"].as_array_mut().unwrap().push(json!({"hooks": [current_handler()]}));
        let mut d = installed();
        d["hooks"]["Stop"] = json!([{"hooks": [{"type": "command", "command": "say done"}, current_handler()]}]);
        let mut e = installed();
        e["hooks"]["Notification"][0]["matcher"] = json!("permission_prompt");
        let mut f = installed();
        f["hooks"]["PreToolUse"] = json!([{"hooks": [current_handler()]}]);
        let mut g = installed();
        g["hooks"]["Stop"][0]["hooks"][0]["timeout"] = json!(30);
        vec![
            ("a", json!({"hooks": {"Notification": [{"hooks": [bare.clone()]}], "Stop": [{"hooks": [bare.clone()]}], "UserPromptSubmit": [{"hooks": [bare.clone()]}], "SessionStart": [{"hooks": [bare]}]}})),
            ("b", b),
            ("c", c),
            ("d", d),
            ("e", e),
            ("f", f),
            ("a hand-edited timeout", g),
        ]
    }

    fn ours_count(root: &Value) -> usize {
        root["hooks"].as_object().into_iter().flat_map(|h| h.values()).flat_map(|g| g.as_array().unwrap())
            .flat_map(|g| g["hooks"].as_array().unwrap()).filter(|h| is_ours(h)).count()
    }

    #[test]
    fn s10_an_old_form_is_not_current_and_install_makes_it_current() {
        for (name, mut root) in old_forms() {
            assert!(!is_current(&root), "({name}) is current");
            remove_ours(&mut root);
            add_current(&mut root);
            assert!(is_current(&root), "({name}) after install: {root}");
            assert_eq!(ours_count(&root), 4, "({name})");
        }
    }

    #[test]
    fn s10_ours_leaves_a_users_group_for_a_group_of_its_own() {
        let (_, mut root) = old_forms().into_iter().find(|(n, _)| *n == "d").unwrap();
        remove_ours(&mut root);
        add_current(&mut root);
        assert_eq!(
            root["hooks"]["Stop"],
            json!([{"hooks": [{"type": "command", "command": "say done"}]}, {"hooks": [current_handler()]}])
        );
    }

    #[test]
    fn s11_a_container_that_was_already_empty_stays() {
        let mut root = json!({"hooks": {"Stop": []}});
        assert!(!remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [], "PreToolUse": [{"hooks": [current_handler()]}]}});
        assert!(remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [{"hooks": []}, {"hooks": [current_handler()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"hooks": []}]}}));
    }

    #[test]
    fn s11_a_group_keeps_its_matcher_while_it_has_another_handler() {
        let foreign = json!({"type": "command", "command": "say x"});
        let mut root = json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [current_handler(), foreign.clone()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [foreign]}]}}));
    }

    #[test]
    fn s11_a_group_and_the_hooks_key_go_when_the_removal_empties_them() {
        let mut root = json!({"model": "x", "hooks": {"Stop": [{"matcher": "x", "hooks": [current_handler()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"model": "x"}));

        let mut root = installed();
        remove_ours(&mut root);
        assert_eq!(root, json!({}));
    }

    #[test]
    fn s13_user_scope_follows_claude_config_dir_and_project_scope_is_the_local_file() {
        let env = Env { home: "/home/u".into(), claude_config_dir: None, cwd: "/work/repo".into() };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/home/u/.claude/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
        let env = Env { claude_config_dir: Some("/cfg".into()), ..env };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/cfg/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
    }

    const F_ODD: &str = "{\n  \"u\": \"\\u00e9\",\n  \"d\": \"first\",\n  \"s\": \"a\\/b\",\n  \"n\": 1.50,\n  \"e\": 1e3,\n  \"arr\": [1, 2, 3],\n  \"o\": { },\n  \"d\": \"last\"\n}\n";

    // The accepted changes of a parse and a re-write, predicted by hand.
    #[test]
    fn s17_an_odd_file_changes_only_as_the_accepted_list_says() {
        let mut root: Value = serde_json::from_str(F_ODD).unwrap();
        add_current(&mut root);
        let installed_text = render(&root, Some(F_ODD));
        let mut root: Value = serde_json::from_str(&installed_text).unwrap();
        remove_ours(&mut root);

        assert_eq!(
            render(&root, Some(&installed_text)),
            "{\n  \"u\": \"é\",\n  \"d\": \"last\",\n  \"s\": \"a/b\",\n  \"n\": 1.5,\n  \"e\": 1000.0,\n  \"arr\": [\n    1,\n    2,\n    3\n  ],\n  \"o\": {}\n}\n"
        );
    }
}
