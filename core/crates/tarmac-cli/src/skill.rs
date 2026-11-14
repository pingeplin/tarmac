//! `tarmac skill` — print the agent-facing guide, or install a `SKILL.md` that
//! points at it into a coding agent's skills directory. Never touches the daemon.
//!
//! Two documents ship inside the binary because the cask-installed CLI has no
//! checkout to read them from. `GUIDE.md` is printed verbatim, so it is always
//! the guide of the binary that ran. `SKILL.md` is copied verbatim and nothing
//! refreshes a copy after an update, so it is a shim that names the verb and
//! carries no rule that could go stale. Keep both self-contained (no repo paths,
//! no relative links): they are read on a machine with no checkout.

use std::fs;
use std::path::{Path, PathBuf};

use crate::agents::{Env, Scope, Target, parse_flags};

const GUIDE: &str = include_str!("GUIDE.md");

const SHIM: &str = include_str!("SKILL.md");

const SKILL_NAME: &str = "tarmac";

/// The flags `agents::parse_flags` accepts. `main.rs` splices it into `--help`;
/// a usage error prints it verbatim.
pub const USAGE: &str = "    --target claude-code|codex|all   default: all
    --scope  user|project            default: user
    --dry-run                        print the paths, write nothing
";

/// Where one target's `SKILL.md` belongs. Codex's user scope is keyed on `$HOME`
/// and not on `$CODEX_HOME` — the latter only reaches its deprecated root.
pub(crate) fn skill_path(target: Target, scope: Scope, env: &Env) -> PathBuf {
    let root = match scope {
        Scope::User => target.user_root(env),
        Scope::Project => env.cwd.join(target.config_dir()),
    };
    root.join("skills").join(SKILL_NAME).join("SKILL.md")
}

fn write_skill(path: &Path, doc: &str) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent).map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
    fs::write(path, doc).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Returns the exit code: 0 ok, 1 a target failed, 2 usage.
pub fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        None => {
            print!("{GUIDE}");
            0
        }
        Some("install") => install(&args[1..]),
        Some(other) => {
            eprintln!("tarmac: unknown skill subcommand '{other}' (see tarmac --help)");
            2
        }
    }
}

/// Every target is attempted — one unwritable root must not deny the other
/// agent its skill — so the exit code is the aggregate, not the first failure.
fn install(args: &[String]) -> i32 {
    let parsed = match parse_flags(args) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("tarmac: {e}\n{USAGE}");
            return 2;
        }
    };
    let Some(env) = Env::from_process() else { return 1 };
    let mut failed = false;
    for target in parsed.targets {
        let path = skill_path(target, parsed.scope, &env);
        if parsed.dry_run {
            println!("would install {}", path.display());
            continue;
        }
        match write_skill(&path, SHIM) {
            Ok(()) => println!("installed {}", path.display()),
            Err(e) => {
                eprintln!("tarmac: {e}");
                failed = true;
            }
        }
    }
    i32::from(failed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env() -> Env {
        Env {
            home: PathBuf::from("/home/u"),
            claude_config_dir: None,
            cwd: PathBuf::from("/work/repo"),
        }
    }

    #[track_caller]
    fn assert_skill_path(e: &Env, target: Target, scope: Scope, want: &str) {
        assert_eq!(skill_path(target, scope, e), PathBuf::from(want));
    }

    #[test]
    fn user_scope_paths_match_each_agents_own_convention() {
        let e = env();
        assert_skill_path(&e, Target::ClaudeCode, Scope::User, "/home/u/.claude/skills/tarmac/SKILL.md");
        assert_skill_path(&e, Target::Codex, Scope::User, "/home/u/.agents/skills/tarmac/SKILL.md");
    }

    #[test]
    fn project_scope_is_rooted_at_cwd() {
        let e = env();
        assert_skill_path(&e, Target::ClaudeCode, Scope::Project, "/work/repo/.claude/skills/tarmac/SKILL.md");
        assert_skill_path(&e, Target::Codex, Scope::Project, "/work/repo/.agents/skills/tarmac/SKILL.md");
    }

    #[test]
    fn claude_config_dir_displaces_home_but_only_for_user_scope() {
        let e = Env { claude_config_dir: Some(PathBuf::from("/xdg/claude")), ..env() };
        assert_skill_path(&e, Target::ClaudeCode, Scope::User, "/xdg/claude/skills/tarmac/SKILL.md");
        assert_skill_path(&e, Target::ClaudeCode, Scope::Project, "/work/repo/.claude/skills/tarmac/SKILL.md");
        // Codex has no such override — its user root is keyed on $HOME.
        assert_skill_path(&e, Target::Codex, Scope::User, "/home/u/.agents/skills/tarmac/SKILL.md");
    }

    /// The frontmatter as key → value, so the contract can be asserted without
    /// pinning key order or forbidding a future third key.
    fn frontmatter() -> Vec<(&'static str, &'static str)> {
        let rest = SHIM.strip_prefix("---\n").expect("frontmatter must open on line 1");
        let block = rest.split_once("\n---\n").expect("frontmatter must be closed").0;
        block.lines().filter_map(|l| l.split_once(": ")).collect()
    }

    fn field(key: &str) -> &'static str {
        frontmatter().into_iter().find(|(k, _)| *k == key).unwrap_or_else(|| panic!("missing `{key}`")).1
    }

    // The shim ships as-is, so its frontmatter is the contract with both agents:
    // Claude Code treats every field as optional, Codex requires a non-empty
    // `name` (<= 64 chars) and `description`.
    #[test]
    fn the_shim_is_a_valid_skill_for_both_agents() {
        assert_eq!(field("name"), SKILL_NAME);
        assert!(SKILL_NAME.len() <= 64, "Codex caps `name` at 64 chars");
        assert!(!field("description").trim_matches('"').trim().is_empty());
    }

    #[test]
    fn the_shim_names_the_verb_and_carries_no_guide() {
        assert!(SHIM.contains("`tarmac skill`"));
        assert!(SHIM.contains("tarmac open <path>"));
        assert!(!SHIM.contains("tarmac-zoom"));
    }

    #[test]
    fn the_guide_opens_on_its_title_with_no_frontmatter() {
        assert!(GUIDE.starts_with("# Tarmac for coding agents\n"));
        assert!(GUIDE.contains("## Surfacing a file"));
        assert!(GUIDE.contains("tarmac-zoom"));
    }

    #[test]
    fn the_guide_says_which_files_get_which_mode() {
        for phrase in
            ["standards mode", "quirks mode", "document.scrollingElement", "body.scrollTop", "<head>"]
        {
            assert!(GUIDE.contains(phrase), "the guide never says `{phrase}`");
        }
    }

    // Both are read on a machine with no checkout, so nothing repo-internal may
    // leak in — docs-check's ACTIVE rules do not reach these files.
    #[test]
    fn neither_document_leaks_the_repo() {
        for doc in [SHIM, GUIDE] {
            assert!(!doc.contains("Doc status"));
            for link in doc.split("](").skip(1) {
                let target = link.split(')').next().unwrap_or_default();
                assert!(target.starts_with("http"), "link resolves nowhere off-checkout: {target}");
            }
            // Keep in sync with TOP in scripts/docs-check.mjs.
            for repo_path in
                ["core/", "app/", "docs/", "scripts/", "packaging/", ".github/", ".blueprint/"]
            {
                assert!(!doc.contains(repo_path), "leaks a repo path: {repo_path}");
            }
        }
    }
}
