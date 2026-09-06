//! `tarmac skill` — emit the agent-facing guide, and install it as a `SKILL.md`
//! into a coding agent's own skills directory.
//!
//! This verb never touches the daemon socket: it is a pure local file operation,
//! so it works with nothing running. The guide ships inside the binary because
//! the cask-installed CLI has no repo checkout to read it from.
//!
//! `SKILL.md` beside this file IS the artifact — frontmatter and all. It is
//! printed verbatim and copied verbatim, so what a reviewer reads in the repo is
//! byte-for-byte what an agent reads after `install`. Nothing here rewrites it;
//! keep it self-contained (no repo-internal paths, no relative links), because
//! it is read from a machine that has no checkout.

use std::fs;
use std::path::{Path, PathBuf};

/// The installable document, verbatim. Editing it is the whole authoring story.
const SKILL_DOC: &str = include_str!("SKILL.md");

const SKILL_NAME: &str = "tarmac";

/// `install`'s flags, owned here because this module is what parses them.
/// `main.rs` splices it into `--help`; a usage error prints it verbatim.
pub const USAGE: &str = "    --target claude-code|codex|all   default: all
    --scope  user|project            default: user
    --dry-run                        print the paths, write nothing
";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Target {
    ClaudeCode,
    Codex,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scope {
    User,
    Project,
}

impl Target {
    pub const ALL: [Target; 2] = [Target::ClaudeCode, Target::Codex];

    fn parse(s: &str) -> Option<Self> {
        match s {
            "claude-code" => Some(Target::ClaudeCode),
            "codex" => Some(Target::Codex),
            _ => None,
        }
    }

    /// The config dir each agent roots its skills at, relative to the scope root.
    /// Claude Code reads `.claude/skills`; Codex reads the cross-agent
    /// `.agents/skills` (its `$CODEX_HOME/skills` is deprecated back-compat).
    fn config_dir(self) -> &'static str {
        match self {
            Target::ClaudeCode => ".claude",
            Target::Codex => ".agents",
        }
    }

    /// The user-scope root. The inner match is deliberately exhaustive on
    /// `Target`: a new agent must answer "does it have a config-dir override?"
    /// at the compiler's insistence rather than inherit a wildcard's answer.
    fn user_root(self, env: &Env) -> PathBuf {
        match self {
            Target::ClaudeCode => env.claude_config_dir.clone(),
            Target::Codex => None,
        }
        .unwrap_or_else(|| env.home.join(self.config_dir()))
    }
}

impl Scope {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Scope::User),
            "project" => Some(Scope::Project),
            _ => None,
        }
    }
}

/// Everything about the machine that decides where a skill lands. Injected so
/// the path logic is testable without touching a real `$HOME`.
pub struct Env {
    pub home: PathBuf,
    /// `$CLAUDE_CONFIG_DIR`, which displaces `$HOME/.claude` when set.
    pub claude_config_dir: Option<PathBuf>,
    pub cwd: PathBuf,
}

impl Env {
    pub fn from_process() -> Result<Self, String> {
        let home = crate::env_override("HOME").ok_or_else(|| "HOME is not set".to_string())?;
        let cwd = std::env::current_dir().map_err(|e| format!("cannot read cwd: {e}"))?;
        Ok(Env {
            home: PathBuf::from(home),
            claude_config_dir: crate::env_override("CLAUDE_CONFIG_DIR").map(PathBuf::from),
            cwd,
        })
    }
}

/// Where one target's `SKILL.md` belongs. Codex's user scope is keyed on `$HOME`
/// and not on `$CODEX_HOME` — the latter only reaches its deprecated root.
pub fn skill_path(target: Target, scope: Scope, env: &Env) -> PathBuf {
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

struct InstallArgs {
    targets: Vec<Target>,
    scope: Scope,
    dry_run: bool,
}

fn parse_install(args: &[String]) -> Result<InstallArgs, String> {
    let mut targets = Target::ALL.to_vec();
    let mut scope = Scope::User;
    let mut dry_run = false;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            "--target" => {
                let v = it.next().ok_or("--target needs a value")?;
                targets = if v == "all" {
                    Target::ALL.to_vec()
                } else {
                    vec![Target::parse(v).ok_or_else(|| {
                        format!("unknown target '{v}' (claude-code, codex, all)")
                    })?]
                };
            }
            "--scope" => {
                let v = it.next().ok_or("--scope needs a value")?;
                scope = Scope::parse(v)
                    .ok_or_else(|| format!("unknown scope '{v}' (user, project)"))?;
            }
            other => return Err(format!("unexpected argument '{other}'")),
        }
    }
    Ok(InstallArgs { targets, scope, dry_run })
}

/// `tarmac skill [install …]`. Returns the process exit code: 0 ok, 1 a target
/// failed, 2 usage.
pub fn run(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        None => {
            print!("{SKILL_DOC}");
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
    let parsed = match parse_install(args) {
        Ok(p) => p,
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
    for target in parsed.targets {
        let path = skill_path(target, parsed.scope, &env);
        if parsed.dry_run {
            println!("would install {}", path.display());
            continue;
        }
        match write_skill(&path, SKILL_DOC) {
            Ok(()) => println!("installed {}", path.display()),
            Err(e) => {
                eprintln!("tarmac: {e}");
                failed = true;
            }
        }
    }
    if failed { 1 } else { 0 }
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

    #[test]
    fn user_scope_paths_match_each_agents_own_convention() {
        let e = env();
        assert_eq!(
            skill_path(Target::ClaudeCode, Scope::User, &e),
            PathBuf::from("/home/u/.claude/skills/tarmac/SKILL.md")
        );
        assert_eq!(
            skill_path(Target::Codex, Scope::User, &e),
            PathBuf::from("/home/u/.agents/skills/tarmac/SKILL.md")
        );
    }

    #[test]
    fn project_scope_is_rooted_at_cwd() {
        let e = env();
        assert_eq!(
            skill_path(Target::ClaudeCode, Scope::Project, &e),
            PathBuf::from("/work/repo/.claude/skills/tarmac/SKILL.md")
        );
        assert_eq!(
            skill_path(Target::Codex, Scope::Project, &e),
            PathBuf::from("/work/repo/.agents/skills/tarmac/SKILL.md")
        );
    }

    #[test]
    fn claude_config_dir_displaces_home_but_only_for_user_scope() {
        let e = Env { claude_config_dir: Some(PathBuf::from("/xdg/claude")), ..env() };
        assert_eq!(
            skill_path(Target::ClaudeCode, Scope::User, &e),
            PathBuf::from("/xdg/claude/skills/tarmac/SKILL.md")
        );
        assert_eq!(
            skill_path(Target::ClaudeCode, Scope::Project, &e),
            PathBuf::from("/work/repo/.claude/skills/tarmac/SKILL.md")
        );
        // Codex has no such override — its user root is keyed on $HOME.
        assert_eq!(
            skill_path(Target::Codex, Scope::User, &e),
            PathBuf::from("/home/u/.agents/skills/tarmac/SKILL.md")
        );
    }

    /// The frontmatter as key → value, so the contract can be asserted without
    /// pinning key order or forbidding a future third key.
    fn frontmatter() -> Vec<(&'static str, &'static str)> {
        let rest = SKILL_DOC.strip_prefix("---\n").expect("frontmatter must open on line 1");
        let block = rest.split_once("\n---\n").expect("frontmatter must be closed").0;
        block.lines().filter_map(|l| l.split_once(": ")).collect()
    }

    fn field(key: &str) -> &'static str {
        frontmatter().into_iter().find(|(k, _)| *k == key).unwrap_or_else(|| panic!("missing `{key}`")).1
    }

    // The embedded file is shipped as-is, so its frontmatter is the contract with
    // both agents: Claude Code treats every field as optional, Codex requires a
    // non-empty `name` (<= 64 chars) and `description`. One envelope serves both.
    #[test]
    fn the_embedded_document_is_a_valid_skill_for_both_agents() {
        assert_eq!(field("name"), SKILL_NAME);
        assert!(SKILL_NAME.len() <= 64, "Codex caps `name` at 64 chars");
        assert!(!field("description").trim_matches('"').trim().is_empty());
    }

    #[test]
    fn the_document_body_follows_the_frontmatter_and_carries_the_guide() {
        assert!(SKILL_DOC.contains("\n---\n\n# Tarmac for coding agents\n"));
        assert!(SKILL_DOC.contains("## Surfacing a file"));
        assert!(SKILL_DOC.contains("tarmac-zoom"));
        // It is read on a machine with no checkout, so nothing repo-internal may
        // leak in — docs-check's ACTIVE rules do not reach this file.
        assert!(!SKILL_DOC.contains("Doc status"));
        for link in SKILL_DOC.split("](").skip(1) {
            let target = link.split(')').next().unwrap_or_default();
            assert!(target.starts_with("http"), "link resolves nowhere off-checkout: {target}");
        }
        // Keep in sync with TOP in scripts/docs-check.mjs.
        for repo_path in
            ["core/", "desktop/", "docs/", "scripts/", "packaging/", ".github/", ".blueprint/"]
        {
            assert!(!SKILL_DOC.contains(repo_path), "leaks a repo path: {repo_path}");
        }
    }

    #[test]
    fn install_defaults_to_every_target_at_user_scope() {
        let a = parse_install(&[]).unwrap();
        assert_eq!(a.targets, Target::ALL.to_vec());
        assert_eq!(a.scope, Scope::User);
        assert!(!a.dry_run);
    }

    #[test]
    fn install_flags_narrow_target_and_scope() {
        let args: Vec<String> =
            ["--target", "codex", "--scope", "project", "--dry-run"].iter().map(|s| s.to_string()).collect();
        let a = parse_install(&args).unwrap();
        assert_eq!(a.targets, vec![Target::Codex]);
        assert_eq!(a.scope, Scope::Project);
        assert!(a.dry_run);
    }

    #[test]
    fn usage_text_documents_every_flag_the_parser_accepts() {
        for flag in ["--target", "--scope", "--dry-run"] {
            assert!(USAGE.contains(flag), "USAGE omits {flag}");
        }
    }

    #[test]
    fn install_rejects_unknown_values_and_stray_arguments() {
        let bad = |v: &[&str]| {
            parse_install(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>()).is_err()
        };
        assert!(bad(&["--target", "cursor"]));
        assert!(bad(&["--scope", "system"]));
        assert!(bad(&["--target"]));
        assert!(bad(&["extra"]));
    }
}
