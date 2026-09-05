use std::process::Command;

fn tarmac() -> Command {
    Command::new(env!("CARGO_BIN_EXE_tarmac"))
}

#[test]
fn help_exits_zero_and_documents_open() {
    let out = tarmac().arg("--help").output().unwrap();
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("tarmac open <path>"));
    assert!(text.contains("TARMAC_SOCKET"));
}

#[test]
fn no_args_exits_with_usage_error() {
    let out = tarmac().output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn unknown_command_exits_with_usage_error() {
    let out = tarmac().arg("frobnicate").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown command"));
}

#[test]
fn missing_file_is_a_clear_one_line_error() {
    let out = tarmac().args(["open", "/definitely/not/here.md"]).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(err.lines().count(), 1, "expected one line, got: {err}");
    assert!(err.contains("cannot open"));
}

#[test]
fn no_daemon_is_a_clear_one_line_error() {
    let dir = std::env::temp_dir().join(format!("tarmac-cli-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("doc.md");
    std::fs::write(&file, "# hi\n").unwrap();

    let out = tarmac()
        .env("TARMAC_SOCKET", dir.join("absent.sock"))
        .args(["open", file.to_str().unwrap()])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(err.lines().count(), 1, "expected one line, got: {err}");
    assert!(err.contains("no tarmac daemon running"));

    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------- tarmac skill
// `skill` is a pure local file verb: every test below pins HOME (and clears
// CLAUDE_CONFIG_DIR) to a scratch dir so nothing can reach the real `~`.

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("tarmac-skill-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn skill_in(home: &std::path::Path) -> Command {
    let mut cmd = tarmac();
    cmd.env("HOME", home).env_remove("CLAUDE_CONFIG_DIR").arg("skill");
    cmd
}

#[test]
fn skill_prints_the_guide_without_the_repo_only_banner() {
    let home = scratch("print");
    let out = skill_in(&home).output().unwrap();
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("# Tarmac for coding agents\n"), "got: {:?}", &text[..40.min(text.len())]);
    assert!(!text.contains("Doc status"), "the status banner must not ship");
    assert!(text.contains("tarmac open <path>"));
    assert!(text.contains("tarmac-zoom"));
    // Emit is envelope-free: the frontmatter is composed only by `install`.
    assert!(!text.starts_with("---"));
}

#[test]
fn skill_never_talks_to_the_daemon() {
    let home = scratch("nodaemon");
    for args in [vec![], vec!["install"]] {
        let out = skill_in(&home)
            .env("TARMAC_SOCKET", home.join("absent.sock"))
            .args(&args)
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(0), "skill {args:?} must not need a daemon");
    }
}

#[test]
fn install_writes_one_skill_per_target_with_shared_frontmatter() {
    let home = scratch("install");
    let out = skill_in(&home).arg("install").output().unwrap();
    assert!(out.status.success());

    let claude = home.join(".claude/skills/tarmac/SKILL.md");
    let codex = home.join(".agents/skills/tarmac/SKILL.md");
    let stdout = String::from_utf8_lossy(&out.stdout);
    for path in [&claude, &codex] {
        assert!(path.exists(), "{} was not written", path.display());
        assert!(stdout.contains(&path.display().to_string()), "install must report {}", path.display());
        let doc = std::fs::read_to_string(path).unwrap();
        let mut lines = doc.lines();
        assert_eq!(lines.next(), Some("---"));
        assert_eq!(lines.next(), Some("name: tarmac"));
        assert!(lines.next().unwrap().starts_with("description: \""));
        assert_eq!(lines.next(), Some("---"));
        assert!(doc.contains("\n---\n\n# Tarmac for coding agents\n"));
    }
    // Both targets get byte-identical documents, and the body is exactly what
    // `tarmac skill` prints.
    let body = String::from_utf8_lossy(&skill_in(&home).output().unwrap().stdout).into_owned();
    assert_eq!(std::fs::read_to_string(&claude).unwrap(), std::fs::read_to_string(&codex).unwrap());
    assert!(std::fs::read_to_string(&claude).unwrap().ends_with(&body));
}

#[test]
fn install_target_flag_narrows_to_one_agent() {
    let home = scratch("target");
    let out = skill_in(&home).args(["install", "--target", "codex"]).output().unwrap();
    assert!(out.status.success());
    assert!(home.join(".agents/skills/tarmac/SKILL.md").exists());
    assert!(!home.join(".claude").exists(), "claude-code must be untouched");
}

#[test]
fn install_claude_config_dir_displaces_the_home_default() {
    let home = scratch("configdir");
    let cfg = home.join("xdg-claude");
    let out = tarmac()
        .env("HOME", &home)
        .env("CLAUDE_CONFIG_DIR", &cfg)
        .args(["skill", "install", "--target", "claude-code"])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(cfg.join("skills/tarmac/SKILL.md").exists());
    assert!(!home.join(".claude").exists());
}

#[test]
fn install_project_scope_is_rooted_at_the_working_directory() {
    let home = scratch("project");
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let out = skill_in(&home).current_dir(&repo).args(["install", "--scope", "project"]).output().unwrap();
    assert!(out.status.success());
    assert!(repo.join(".claude/skills/tarmac/SKILL.md").exists());
    assert!(repo.join(".agents/skills/tarmac/SKILL.md").exists());
    assert!(!home.join(".claude").exists(), "project scope must not touch the user scope");
}

#[test]
fn install_is_idempotent() {
    let home = scratch("idempotent");
    let path = home.join(".claude/skills/tarmac/SKILL.md");
    assert!(skill_in(&home).arg("install").output().unwrap().status.success());
    let first = std::fs::read_to_string(&path).unwrap();
    assert!(skill_in(&home).arg("install").output().unwrap().status.success());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), first);
}

#[test]
fn dry_run_reports_every_path_and_writes_nothing() {
    let home = scratch("dryrun");
    let out = skill_in(&home).args(["install", "--dry-run"]).output().unwrap();
    assert_eq!(out.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains(&home.join(".claude/skills/tarmac/SKILL.md").display().to_string()));
    assert!(stdout.contains(&home.join(".agents/skills/tarmac/SKILL.md").display().to_string()));
    assert!(!home.join(".claude").exists());
    assert!(!home.join(".agents").exists());
}

#[test]
fn one_unwritable_target_fails_without_denying_the_other() {
    let home = scratch("partial");
    // A regular file where the config dir belongs: create_dir_all cannot pass.
    std::fs::write(home.join(".claude"), "not a directory").unwrap();

    let out = skill_in(&home).arg("install").output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains(".claude"), "the failure must name the path: {err}");
    assert!(
        home.join(".agents/skills/tarmac/SKILL.md").exists(),
        "codex must still be installed when claude-code fails"
    );
}

#[test]
fn skill_usage_errors_exit_two() {
    let home = scratch("usage");
    for args in [
        vec!["frobnicate"],
        vec!["install", "--target", "cursor"],
        vec!["install", "--scope", "system"],
        vec!["install", "--target"],
        vec!["install", "extra"],
    ] {
        let out = skill_in(&home).args(&args).output().unwrap();
        assert_eq!(out.status.code(), Some(2), "skill {args:?} should be a usage error");
    }
}

#[test]
fn help_documents_the_skill_verb_too() {
    let out = tarmac().arg("--help").output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("tarmac skill"));
    assert!(text.contains("tarmac skill install"));
}
