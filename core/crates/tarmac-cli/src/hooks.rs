//! `tarmac hooks`: Claude Code reports through one fixed hook entry (spec
//! 2611.0010). The settings file holds only a call to `tarmac hooks run claude`;
//! the mapping from a hook's input to a report lives here, so an upgrade of the
//! binary updates it. Only the cli knows an agent: the daemon gets a plain
//! `report`.

use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use serde::Serialize;
use serde_json::ser::{PrettyFormatter, Serializer};
use serde_json::{Map, Value, json};
use tarmac_protocol::{Msg, cap_report_text};

use crate::agents::{Env, Scope, Target, parse_flags};
use crate::report;

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
    let env = match Env::from_process() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("tarmac: {e}");
            return 1;
        }
    };
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
    let mut settings = load(path)?;
    let shown = path.display();
    match verb {
        Verb::Install if is_current(&settings.root) => return Ok(vec![format!("already installed: {shown}")]),
        Verb::Install if dry_run => return Ok(vec![format!("would install: {shown}")]),
        Verb::Install => {
            remove_ours(&mut settings.root);
            add_current(&mut settings.root);
        }
        Verb::Uninstall if settings.original.is_none() || !remove_ours(&mut settings.root) => {
            return Ok(vec![format!("not installed: {shown}")]);
        }
        Verb::Uninstall if dry_run => return Ok(vec![format!("would uninstall: {shown}")]),
        Verb::Uninstall => {}
    }
    let backup = write(&settings)?;
    let done = if verb == Verb::Install { "installed" } else { "uninstalled" };
    let mut lines = vec![format!("{done}: {shown}")];
    lines.extend(backup.iter().map(|b| format!("backup: {}", b.display())));
    if scope == Scope::Project {
        lines.push(format!(
            "hint: git ignores {real} only if you add it to .gitignore (Claude does this only for a file it made); the same holds for {backup}",
            real = settings.real.display(),
            backup = backup_path(&settings.real).display(),
        ));
    }
    Ok(lines)
}

/// A settings file as read.
struct Settings {
    /// The file that a write replaces: the target, when the path is a symlink.
    real: PathBuf,
    /// The text, or `None` for a file that does not exist yet.
    original: Option<String>,
    root: Value,
}

/// Reads and checks `path`. A file that would be refused is refused here, so
/// `--dry-run` and `status` see the same refusal as a write.
fn load(path: &Path) -> Result<Settings, String> {
    let real = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            fs::canonicalize(path).map_err(|e| format!("a symlink whose target cannot be read ({e})"))?
        }
        _ => path.to_path_buf(),
    };
    let bytes = match fs::read(&real) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Settings { real, original: None, root: json!({}) });
        }
        Err(e) => return Err(format!("cannot read it ({e})")),
    };
    let text = String::from_utf8(bytes).map_err(|_| "it is not UTF-8".to_string())?;
    if text.is_empty() {
        return Err("the file is empty, and an empty file is not JSON".into());
    }
    if text.starts_with('\u{feff}') {
        return Err("the file starts with a BOM, which JSON does not allow".into());
    }
    let root: Value = serde_json::from_str(&text).map_err(|e| format!("it is not valid JSON ({e})"))?;
    check_shape(&root)?;
    Ok(Settings { real, original: Some(text), root })
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

fn backup_path(real: &Path) -> PathBuf {
    let mut name = real.as_os_str().to_owned();
    name.push(".tarmac-backup");
    PathBuf::from(name)
}

/// Writes `settings` atomically through a temp file beside the real file, and
/// returns the backup of the old one. Both probes come before the backup: a
/// read-only file must not be replaced by the rename, and a directory that
/// takes no temp file must not get a backup.
fn write(settings: &Settings) -> Result<Option<PathBuf>, String> {
    let real = &settings.real;
    let dir = real.parent().ok_or("it has no parent directory")?;
    let mut tmp_name = std::ffi::OsString::from(".");
    tmp_name.push(real.file_name().ok_or("it has no file name")?);
    tmp_name.push(".tarmac-tmp");
    let tmp = dir.join(tmp_name);
    let cannot_write = |e: io::Error| format!("cannot write it ({e})");

    let mode = match &settings.original {
        Some(_) => {
            OpenOptions::new().write(true).open(real).map_err(cannot_write)?;
            Some(fs::metadata(real).map_err(cannot_write)?.permissions().mode())
        }
        None => {
            fs::create_dir_all(dir).map_err(|e| format!("cannot create {} ({e})", dir.display()))?;
            None
        }
    };
    let _ = fs::remove_file(&tmp);
    // A new file gets the default mode; an existing one is never briefly wider
    // than its own.
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(if mode.is_some() { 0o600 } else { 0o666 })
        .open(&tmp)
        .map_err(|e| format!("cannot write in {} ({e})", dir.display()))?;
    let backup = backup_path(real);
    let text = render(&settings.root, settings.original.as_deref());
    let written = (|| {
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        if let (Some(mode), Some(original)) = (mode, &settings.original) {
            file.set_permissions(fs::Permissions::from_mode(mode))?;
            put_backup(&backup, original.as_bytes(), mode)?;
        }
        fs::rename(&tmp, real)
    })();
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(cannot_write(e));
    }
    Ok(mode.map(|_| backup))
}

/// Puts `bytes` at `backup` through a new temp file and a rename: a symlink
/// planted at `backup` is replaced, never written through.
fn put_backup(backup: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let mut tmp = backup.as_os_str().to_owned();
    tmp.push("-tmp");
    let tmp = PathBuf::from(tmp);
    let _ = fs::remove_file(&tmp);
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    let written = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        fs::rename(&tmp, backup)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    written
}

/// Exit 1 when a file is unreadable; `not installed` is not an error.
fn status() -> i32 {
    let env = match Env::from_process() {
        Ok(e) => e,
        Err(e) => {
            eprintln!("tarmac: {e}");
            return 1;
        }
    };
    let mut unreadable = false;
    let mut rows = Vec::new();
    for (scope, name) in [(Scope::User, "user"), (Scope::Project, "project")] {
        let path = claude_settings_path(scope, &env);
        let state = match load(&path) {
            Ok(s) if is_current(&s.root) => "installed".to_string(),
            Ok(s) if ours(&s.root).next().is_some() => OLD_FORM.to_string(),
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

/// The first `tarmac` on this process's `PATH` that runs, as the entry plus
/// `tarmac`. A hook sees `claude`'s `PATH`, which is this one only when both
/// started from the same shell.
fn path_tarmac() -> String {
    let runs = |candidate: &PathBuf| {
        fs::metadata(candidate).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    let found = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).map(|dir| dir.join("tarmac")).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .find(runs);
    let Some(found) = found else { return "not found (the hooks will do nothing)".into() };
    let this = std::env::current_exe().and_then(fs::canonicalize).ok();
    let which = if fs::canonicalize(&found).ok() == this && this.is_some() {
        "this binary"
    } else {
        "another binary than this one"
    };
    format!("{} ({which})", found.display())
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
    let input: Value = serde_json::from_slice(&read_input()?).map_err(|e| format!("the input is not JSON: {e}"))?;
    if !input.is_object() {
        return Err("the input is not a JSON object".into());
    }
    let Some((kind, text)) = claude_report(&input) else { return Ok(()) };
    let msg = Msg::Report { term_id: term_id.to_string_lossy().into_owned(), kind: kind.to_owned(), text };
    report::send(&msg, HOOK_DEADLINE, &format!("no answer from the daemon in {} ms", HOOK_DEADLINE.as_millis()))
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

/// A report as the wire spells it: the kind and the optional text.
pub(crate) type HookReport = (&'static str, Option<String>);

/// The report a Claude hook input stands for, if any. `SessionStart` is
/// installed but maps to nothing until slice 4.
pub(crate) fn claude_report(input: &Value) -> Option<HookReport> {
    let field = |key: &str| input.get(key);
    match field("hook_event_name")?.as_str()? {
        "Notification" if field("notification_type").and_then(Value::as_str) == Some("permission_prompt") => {
            Some(("blocked", report_text(field("message"))))
        }
        "Stop" => Some(("done", report_text(field("last_assistant_message")))),
        "UserPromptSubmit" => Some(("clear", None)),
        _ => None,
    }
}

/// The text without its control characters, its whitespace runs folded, and
/// capped. Removal comes first so that `"a \u{1b} b"` folds to `"a b"`.
fn report_text(field: Option<&Value>) -> Option<String> {
    let kept: String = field?.as_str()?.chars().filter(|c| !c.is_control() || c.is_whitespace()).collect();
    let folded = kept.split_whitespace().collect::<Vec<_>>().join(" ");
    (!folded.is_empty()).then(|| cap_report_text(&folded))
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

fn handlers(group: &Value) -> impl Iterator<Item = &Value> {
    group.get("hooks").and_then(Value::as_array).into_iter().flatten()
}

fn ours(root: &Value) -> impl Iterator<Item = &Value> {
    groups(root).flat_map(|(_, group)| handlers(group)).filter(|h| is_ours(h))
}

/// Whether the handlers that are ours are exactly the current four: one alone
/// in a group with no other key under each event.
fn is_current(root: &Value) -> bool {
    let ours = ours(root).count();
    let current_group = json!({"hooks": [current_handler()]});
    ours == EVENTS.len()
        && EVENTS.iter().all(|event| {
            groups(root).filter(|(e, group)| e == event && **group == current_group).count() == 1
        })
}

/// Removes every handler of ours, and prunes only what that emptied, with
/// `shift_remove` so that no other key moves. Whether any was removed.
fn remove_ours(root: &mut Value) -> bool {
    let Some(root) = root.as_object_mut() else { return false };
    let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) else { return false };
    let mut removed = false;
    let mut emptied = Vec::new();
    for (event, groups) in hooks.iter_mut() {
        let Some(groups) = groups.as_array_mut() else { continue };
        let had = groups.len();
        groups.retain_mut(|group| {
            let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else { return true };
            let before = handlers.len();
            handlers.retain(|h| !is_ours(h));
            if handlers.len() == before {
                return true;
            }
            removed = true;
            !handlers.is_empty()
        });
        if had > 0 && groups.is_empty() {
            emptied.push(event.clone());
        }
    }
    for event in emptied {
        hooks.shift_remove(&event);
    }
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

/// The indent of the file's first indented line: a tab, or that many spaces.
/// Two spaces, Claude Code's own, when no line is indented.
fn indent_unit(text: &str) -> String {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .find_map(|line| match line.as_bytes().first() {
            Some(b'\t') => Some("\t".to_string()),
            Some(b' ') => Some(" ".repeat(line.len() - line.trim_start_matches(' ').len())),
            _ => None,
        })
        .unwrap_or_else(|| "  ".to_string())
}

/// `root` as the file's new text, in the original's indent and final newline.
fn render(root: &Value, original: Option<&str>) -> String {
    let unit = original.map_or_else(|| "  ".to_string(), indent_unit);
    let mut out = Vec::new();
    let mut ser = Serializer::with_formatter(&mut out, PrettyFormatter::with_indent(unit.as_bytes()));
    root.serialize(&mut ser).expect("a Value always serializes");
    if original.is_none_or(|o| o.ends_with('\n')) {
        out.push(b'\n');
    }
    String::from_utf8(out).expect("serde_json writes UTF-8")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tarmac_protocol::REPORT_TEXT_MAX;

    const CURRENT: &str = "tarmac hooks run claude || true";
    const BARE: &str = "tarmac hooks run claude";
    const EVENTS: [&str; 4] = ["Notification", "Stop", "UserPromptSubmit", "SessionStart"];

    fn fixture(name: &str) -> Value {
        let path = format!("{}/tests/fixtures/hooks/{name}.json", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    fn stop(message: Value) -> Value {
        json!({"hook_event_name": "Stop", "last_assistant_message": message})
    }

    fn done_text(message: Value) -> Option<String> {
        let (kind, text) = claude_report(&stop(message)).expect("a Stop is a report");
        assert_eq!(kind, "done");
        text
    }

    fn handler(command: &str) -> Value {
        json!({"type": "command", "command": command, "timeout": 5})
    }

    fn installed() -> Value {
        let mut root = json!({});
        add_current(&mut root);
        root
    }

    // S5
    #[test]
    fn s5_a_permission_notification_is_blocked_with_its_message() {
        let input = json!({
            "hook_event_name": "Notification",
            "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        });
        assert_eq!(claude_report(&input), Some(("blocked", Some("Claude needs your permission to use Bash".into()))));
    }

    // S5, on the input Claude Code 2.1.325 sent (Step 0).
    #[test]
    fn s5_the_captured_inputs_map_as_the_table_says() {
        assert_eq!(
            claude_report(&fixture("notification-permission")),
            Some(("blocked", Some("Claude needs your permission".into())))
        );
        assert_eq!(claude_report(&fixture("stop")), Some(("done", Some("You picked red.".into()))));
        assert_eq!(claude_report(&fixture("user-prompt-submit")), Some(("clear", None)));
        assert_eq!(claude_report(&fixture("session-start")), None);
    }

    // Step 0: Claude Code 2.1.325 sends AskUserQuestion and plan approval as a
    // permission prompt, so they are blocked too.
    #[test]
    fn a_question_and_a_plan_approval_arrive_as_permission_prompts() {
        assert_eq!(
            claude_report(&fixture("notification-ask-user-question")),
            Some(("blocked", Some("Claude needs your permission".into())))
        );
        assert_eq!(
            claude_report(&fixture("notification-plan-approval")),
            Some(("blocked", Some("Claude Code needs your approval for the plan".into())))
        );
    }

    // S5
    #[test]
    fn s5_stop_is_done_with_its_text_folded() {
        assert_eq!(done_text(json!("Done.\n\n  All   tests pass.\n")), Some("Done. All tests pass.".into()));
    }

    // S5
    #[test]
    fn s5_a_prompt_clears_and_a_session_start_is_nothing() {
        let prompt = json!({"hook_event_name": "UserPromptSubmit", "prompt": "x".repeat(10_000)});
        assert_eq!(claude_report(&prompt), Some(("clear", None)));
        assert_eq!(claude_report(&json!({"hook_event_name": "SessionStart", "source": "startup"})), None);
    }

    // S19, on the idle notification Claude Code 2.1.325 sent 60 s after a Stop.
    #[test]
    fn s19_the_captured_idle_notification_is_nothing() {
        assert_eq!(fixture("notification-idle")["notification_type"], "idle_prompt");
        assert_eq!(claude_report(&fixture("notification-idle")), None);
    }

    // S19
    #[test]
    fn s19_other_notifications_are_nothing() {
        for kind in [json!("idle_prompt"), json!("elicitation_dialog"), Value::Null] {
            let mut input = json!({"hook_event_name": "Notification", "message": "Claude is waiting for your input"});
            if !kind.is_null() {
                input["notification_type"] = kind.clone();
            }
            assert_eq!(claude_report(&input), None, "{kind}");
        }
    }

    #[test]
    fn an_unknown_or_missing_event_is_nothing() {
        for input in [json!({"hook_event_name": "PreToolUse"}), json!({"hook_event_name": 7}), json!({}), json!([])] {
            assert_eq!(claude_report(&input), None, "{input}");
        }
    }

    // S18
    #[test]
    fn s18_a_long_text_is_capped_to_280_chars() {
        let text = done_text(json!("a".repeat(400))).unwrap();
        assert_eq!(text.chars().count(), REPORT_TEXT_MAX);
        assert!(text.ends_with('…'));
    }

    // S18
    #[test]
    fn s18_no_text_when_it_is_blank_or_not_a_string() {
        for message in [json!(" \n\t "), json!(""), json!(7)] {
            assert_eq!(done_text(message.clone()), None, "{message}");
        }
        assert_eq!(claude_report(&json!({"hook_event_name": "Stop"})), Some(("done", None)));
    }

    // S18
    #[test]
    fn s18_every_kind_of_whitespace_folds() {
        assert_eq!(done_text(json!("a\t\r\n\u{000b}\u{000c}b")), Some("a b".into()));
    }

    // S18
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

    // S18
    #[test]
    fn s18_the_cap_counts_the_text_after_removal() {
        let letters = "a".repeat(REPORT_TEXT_MAX);
        let with_esc = format!("{}\u{001b}{}", &letters[..140], &letters[140..]);
        assert_eq!(done_text(json!(with_esc)), Some(letters));
    }

    // S9
    #[test]
    fn s9_ours_is_an_exact_command_on_a_command_handler_with_no_args() {
        let ours = [handler(CURRENT), json!({"type": "command", "command": BARE}), json!({"type": "command", "command": " tarmac hooks run claude "})];
        let foreign = [
            json!({"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"}),
            json!({"type": "command", "command": "tarmac hooks run claude --x"}),
            json!({"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]}),
            json!({"type": "command", "command": BARE, "args": []}),
            json!({"type": "prompt", "command": BARE}),
            json!({"command": BARE}),
            json!(BARE),
        ];
        for h in &ours {
            assert!(is_ours(h), "{h}");
        }
        for h in &foreign {
            assert!(!is_ours(h), "{h}");
        }
    }

    // S9
    #[test]
    fn s9_a_removal_keeps_every_foreign_handler_in_its_order() {
        let foreign = vec![
            json!({"type": "command", "command": "/opt/homebrew/bin/tarmac hooks run claude"}),
            json!({"type": "command", "command": "tarmac hooks run claude --x"}),
            json!({"type": "command", "command": "tarmac", "args": ["hooks", "run", "claude"]}),
            json!({"type": "command", "command": BARE, "args": []}),
            json!({"type": "prompt", "command": BARE}),
            json!({"command": BARE}),
            json!(BARE),
        ];
        let mut all = vec![handler(CURRENT), json!({"type": "command", "command": BARE}), json!({"type": "command", "command": " tarmac hooks run claude "})];
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
        assert_eq!(hooks.keys().collect::<Vec<_>>(), EVENTS.iter().collect::<Vec<_>>());
        for event in EVENTS {
            assert_eq!(hooks[event], json!([{"hooks": [handler(CURRENT)]}]), "{event}");
        }
        let text = render(&root, None);
        assert!(text.contains(r#""type": "command",
            "command": "tarmac hooks run claude || true",
            "timeout": 5"#), "{text}");
    }

    fn old_forms() -> Vec<(&'static str, Value)> {
        let bare = json!({"type": "command", "command": BARE});
        let mut b = installed();
        b["hooks"].as_object_mut().unwrap().shift_remove("SessionStart");
        let mut c = installed();
        c["hooks"]["Stop"].as_array_mut().unwrap().push(json!({"hooks": [handler(CURRENT)]}));
        let mut d = installed();
        d["hooks"]["Stop"] = json!([{"hooks": [{"type": "command", "command": "say done"}, handler(CURRENT)]}]);
        let mut e = installed();
        e["hooks"]["Notification"][0]["matcher"] = json!("permission_prompt");
        let mut f = installed();
        f["hooks"]["PreToolUse"] = json!([{"hooks": [handler(CURRENT)]}]);
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

    // S10
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

    // S10 (d)
    #[test]
    fn s10_ours_leaves_a_users_group_for_a_group_of_its_own() {
        let (_, mut root) = old_forms().into_iter().find(|(n, _)| *n == "d").unwrap();
        remove_ours(&mut root);
        add_current(&mut root);
        assert_eq!(
            root["hooks"]["Stop"],
            json!([{"hooks": [{"type": "command", "command": "say done"}]}, {"hooks": [handler(CURRENT)]}])
        );
    }

    // S11
    #[test]
    fn s11_a_container_that_was_already_empty_stays() {
        let mut root = json!({"hooks": {"Stop": []}});
        assert!(!remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [], "PreToolUse": [{"hooks": [handler(CURRENT)]}]}});
        assert!(remove_ours(&mut root));
        assert_eq!(root, json!({"hooks": {"Stop": []}}));

        let mut root = json!({"hooks": {"Stop": [{"hooks": []}, {"hooks": [handler(CURRENT)]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"hooks": []}]}}));
    }

    // S11
    #[test]
    fn s11_a_group_keeps_its_matcher_while_it_has_another_handler() {
        let foreign = json!({"type": "command", "command": "say x"});
        let mut root = json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [handler(CURRENT), foreign.clone()]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"hooks": {"Stop": [{"matcher": "x", "hooks": [foreign]}]}}));
    }

    // S11
    #[test]
    fn s11_a_group_and_the_hooks_key_go_when_the_removal_empties_them() {
        let mut root = json!({"model": "x", "hooks": {"Stop": [{"matcher": "x", "hooks": [handler(CURRENT)]}]}});
        remove_ours(&mut root);
        assert_eq!(root, json!({"model": "x"}));

        let mut root = installed();
        remove_ours(&mut root);
        assert_eq!(root, json!({}));
    }

    // S13
    #[test]
    fn s13_user_scope_follows_claude_config_dir_and_project_scope_is_the_local_file() {
        let env = Env { home: "/home/u".into(), claude_config_dir: None, cwd: "/work/repo".into() };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/home/u/.claude/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
        let env = Env { claude_config_dir: Some("/cfg".into()), ..env };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/cfg/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
    }

    // S17
    #[test]
    fn s17_the_indent_is_the_first_indented_lines() {
        assert_eq!(indent_unit("{\n  \"a\": {\n    \"b\": 1\n  }\n}\n"), "  ");
        assert_eq!(indent_unit("{\n    \"a\": 1\n}"), "    ");
        assert_eq!(indent_unit("{\n\t\"a\": 1\n}\n"), "\t");
        assert_eq!(indent_unit("{}"), "  ");
        assert_eq!(indent_unit("{\"a\": 1}\n"), "  ");
    }

    const F_ODD: &str = "{\n  \"u\": \"\\u00e9\",\n  \"d\": \"first\",\n  \"s\": \"a\\/b\",\n  \"n\": 1.50,\n  \"e\": 1e3,\n  \"arr\": [1, 2, 3],\n  \"o\": { },\n  \"d\": \"last\"\n}\n";

    // S17: the accepted changes of a parse and a re-write, predicted by hand.
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

    #[test]
    fn render_keeps_a_missing_final_newline_and_ends_a_new_file_with_one() {
        let root = json!({"a": [1]});
        assert_eq!(render(&root, Some("{\n    \"a\": []\n}")), "{\n    \"a\": [\n        1\n    ]\n}");
        assert_eq!(render(&root, None), "{\n  \"a\": [\n    1\n  ]\n}\n");
    }
}
