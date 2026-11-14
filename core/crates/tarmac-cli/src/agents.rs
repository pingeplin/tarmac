//! The coding agents the cli writes config for, and the flags that pick them:
//! `skill install`, `hooks install` and `hooks uninstall` share them.

use std::path::PathBuf;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Target {
    ClaudeCode,
    Codex,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Scope {
    User,
    Project,
}

impl Target {
    pub(crate) const ALL: [Target; 2] = [Target::ClaudeCode, Target::Codex];

    pub(crate) fn parse(s: &str) -> Option<Self> {
        match s {
            "claude-code" => Some(Target::ClaudeCode),
            "codex" => Some(Target::Codex),
            _ => None,
        }
    }

    /// Codex reads the cross-agent `.agents/skills`; its `$CODEX_HOME/skills` is
    /// deprecated back-compat.
    pub(crate) fn config_dir(self) -> &'static str {
        match self {
            Target::ClaudeCode => ".claude",
            Target::Codex => ".agents",
        }
    }

    /// The user-scope root. The inner match is deliberately exhaustive on
    /// `Target`: a new agent must answer "does it have a config-dir override?"
    /// at the compiler's insistence rather than inherit a wildcard's answer.
    pub(crate) fn user_root(self, env: &Env) -> PathBuf {
        match self {
            Target::ClaudeCode => env.claude_config_dir.clone(),
            Target::Codex => None,
        }
        .unwrap_or_else(|| env.home.join(self.config_dir()))
    }
}

impl Scope {
    pub(crate) fn parse(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Scope::User),
            "project" => Some(Scope::Project),
            _ => None,
        }
    }
}

/// Everything about the machine that decides where an agent's config lands.
/// Injected so the path logic is testable without touching a real `$HOME`.
pub(crate) struct Env {
    pub(crate) home: PathBuf,
    /// `$CLAUDE_CONFIG_DIR`, which displaces `$HOME/.claude` when set.
    pub(crate) claude_config_dir: Option<PathBuf>,
    pub(crate) cwd: PathBuf,
}

impl Env {
    pub(crate) fn from_process() -> Result<Self, String> {
        let home = crate::env_override("HOME").ok_or_else(|| "HOME is not set".to_string())?;
        let cwd = std::env::current_dir().map_err(|e| format!("cannot read cwd: {e}"))?;
        Ok(Env {
            home: PathBuf::from(home),
            claude_config_dir: crate::env_override("CLAUDE_CONFIG_DIR").map(PathBuf::from),
            cwd,
        })
    }
}

pub(crate) struct Flags {
    pub(crate) targets: Vec<Target>,
    pub(crate) scope: Scope,
    pub(crate) dry_run: bool,
}

pub(crate) fn parse_flags(args: &[String]) -> Result<Flags, String> {
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
    Ok(Flags { targets, scope, dry_run })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skill::USAGE;

    fn install_args(args: &[&str]) -> Result<Flags, String> {
        let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        parse_flags(&owned)
    }

    #[test]
    fn install_defaults_to_every_target_at_user_scope() {
        let a = install_args(&[]).unwrap();
        assert_eq!(a.targets, Target::ALL.to_vec());
        assert_eq!(a.scope, Scope::User);
        assert!(!a.dry_run);
    }

    #[test]
    fn install_flags_narrow_target_and_scope() {
        let a = install_args(&["--target", "codex", "--scope", "project", "--dry-run"]).unwrap();
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
        assert!(install_args(&["--target", "cursor"]).is_err());
        assert!(install_args(&["--scope", "system"]).is_err());
        assert!(install_args(&["--target"]).is_err());
        assert!(install_args(&["extra"]).is_err());
    }
}
