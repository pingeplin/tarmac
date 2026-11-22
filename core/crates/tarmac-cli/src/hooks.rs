//! `tarmac hooks`: Claude Code reports through one fixed hook entry (spec
//! 2611.0010). The settings file holds only a call to `tarmac hooks run claude`;
//! the mapping from a hook's input to a report or a resume command lives here,
//! so an upgrade of the binary updates it. Only the cli knows an agent: the
//! daemon gets a plain `report` or `resume`.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use crate::agents::{Env, Scope, Target, parse_flags};
use crate::settings_file::{self, SettingsFile};

mod input;
mod merge;

use input::run_hook;
use merge::{add_current, check_shape, is_current, ours, remove_ours};

const USAGE: &str = "usage: tarmac hooks install|uninstall [--target claude-code|codex|all] [--scope user|project] [--dry-run]  |  tarmac hooks status  |  tarmac hooks run <agent>";

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn s13_user_scope_follows_claude_config_dir_and_project_scope_is_the_local_file() {
        let env = Env { home: "/home/u".into(), claude_config_dir: None, cwd: "/work/repo".into() };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/home/u/.claude/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
        let env = Env { claude_config_dir: Some("/cfg".into()), ..env };
        assert_eq!(claude_settings_path(Scope::User, &env), Path::new("/cfg/settings.json"));
        assert_eq!(claude_settings_path(Scope::Project, &env), Path::new("/work/repo/.claude/settings.local.json"));
    }
}
