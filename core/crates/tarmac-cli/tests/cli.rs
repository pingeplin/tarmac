use std::path::{Path, PathBuf};
use std::process::Command;

mod common;
use common::{Report, scratch, tarmac};

#[test]
fn help_exits_zero_and_documents_open() {
    let out = Report::of(tarmac().arg("--help"));
    assert!(out.status.success());
    assert!(out.stdout.contains("tarmac open <path>"));
    assert!(out.stdout.contains("TARMAC_SOCKET"));
}

#[test]
fn no_args_exits_with_usage_error() {
    let out = Report::of(&mut tarmac());
    assert_eq!(out.code(), Some(2));
}

#[test]
fn unknown_command_exits_with_usage_error() {
    let out = Report::of(tarmac().arg("frobnicate"));
    assert_eq!(out.code(), Some(2));
    assert!(out.stderr.contains("unknown command"));
}

#[test]
fn missing_file_is_a_clear_one_line_error() {
    let out = Report::of(tarmac().args(["open", "/definitely/not/here.md"]));
    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().contains("cannot open"));
}

#[test]
fn no_daemon_is_a_clear_one_line_error() {
    let dir = scratch();
    let file = dir.join("doc.md");
    std::fs::write(&file, "# hi\n").unwrap();

    let out = Report::of(
        tarmac().env("TARMAC_SOCKET", dir.join("absent.sock")).args(["open", file.to_str().unwrap()]),
    );
    assert_eq!(out.code(), Some(1));
    assert!(out.one_stderr_line().contains("no tarmac daemon running"));
}

// ---------------------------------------------------------------- tarmac skill
// `skill` is a pure local file verb: every test below pins HOME (and clears
// CLAUDE_CONFIG_DIR) to a scratch dir so nothing can reach the real `~`.

fn claude_skill(root: &Path) -> PathBuf {
    root.join(".claude/skills/tarmac/SKILL.md")
}

fn codex_skill(root: &Path) -> PathBuf {
    root.join(".agents/skills/tarmac/SKILL.md")
}

fn skill_in(home: &Path) -> Command {
    let mut cmd = tarmac();
    cmd.env("HOME", home).env_remove("CLAUDE_CONFIG_DIR").arg("skill");
    cmd
}

fn install(home: &Path) -> Report {
    Report::of(skill_in(home).arg("install"))
}

#[test]
fn skill_prints_the_guide_with_no_frontmatter() {
    let home = scratch();
    let out = Report::of(&mut skill_in(&home));
    assert!(out.status.success());
    let text = &out.stdout;
    assert!(
        text.starts_with("# Tarmac for coding agents\n"),
        "got: {:?}",
        &text[..40.min(text.len())]
    );
    assert!(text.contains("tarmac open <path>"));
    assert!(text.contains("tarmac-zoom"));
}

#[test]
fn skill_never_talks_to_the_daemon() {
    let home = scratch();
    for args in [vec![], vec!["install"]] {
        let out =
            Report::of(skill_in(&home).env("TARMAC_SOCKET", home.join("absent.sock")).args(&args));
        assert_eq!(out.code(), Some(0), "skill {args:?} must not need a daemon");
    }
}

#[test]
fn install_writes_the_shim_to_every_target() {
    let home = scratch();
    let out = install(&home);
    assert!(out.status.success());

    let claude = claude_skill(&home);
    let codex = codex_skill(&home);
    for path in [&claude, &codex] {
        assert!(path.exists(), "{} was not written", path.display());
        assert!(
            out.stdout.contains(&path.display().to_string()),
            "install must report {}",
            path.display()
        );
        let written = std::fs::read_to_string(path).unwrap();
        assert!(written.starts_with("---\nname: tarmac\ndescription: "), "{} has no frontmatter", path.display());
        // The shim points at the guide and carries none of it: a rule copied
        // here goes stale with the installed file.
        assert!(written.contains("`tarmac skill`"), "{} must name the verb that prints the guide", path.display());
        assert!(!written.contains("tarmac-zoom"), "{} carries the guide", path.display());
    }
}

#[test]
fn install_target_flag_narrows_to_one_agent() {
    let home = scratch();
    let out = Report::of(skill_in(&home).args(["install", "--target", "codex"]));
    assert!(out.status.success());
    assert!(codex_skill(&home).exists());
    assert!(!home.join(".claude").exists(), "claude-code must be untouched");
}

#[test]
fn install_claude_config_dir_displaces_the_home_default() {
    let home = scratch();
    let cfg = home.join("xdg-claude");
    let out = Report::of(
        tarmac()
            .env("HOME", &home)
            .env("CLAUDE_CONFIG_DIR", &cfg)
            .args(["skill", "install", "--target", "claude-code"]),
    );
    assert!(out.status.success());
    assert!(cfg.join("skills/tarmac/SKILL.md").exists());
    assert!(!home.join(".claude").exists());
}

#[test]
fn install_project_scope_is_rooted_at_the_working_directory() {
    let home = scratch();
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let out = Report::of(skill_in(&home).current_dir(&repo).args(["install", "--scope", "project"]));
    assert!(out.status.success());
    assert!(claude_skill(&repo).exists());
    assert!(codex_skill(&repo).exists());
    assert!(!home.join(".claude").exists(), "project scope must not touch the user scope");
}

#[test]
fn install_is_idempotent() {
    let home = scratch();
    let path = claude_skill(&home);
    assert!(install(&home).status.success());
    let first = std::fs::read_to_string(&path).unwrap();
    assert!(install(&home).status.success());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), first);
}

#[test]
fn dry_run_reports_every_path_and_writes_nothing() {
    let home = scratch();
    let out = Report::of(skill_in(&home).args(["install", "--dry-run"]));
    assert_eq!(out.code(), Some(0));
    assert!(out.stdout.contains(&claude_skill(&home).display().to_string()));
    assert!(out.stdout.contains(&codex_skill(&home).display().to_string()));
    assert!(!home.join(".claude").exists());
    assert!(!home.join(".agents").exists());
}

#[test]
fn one_unwritable_target_fails_without_denying_the_other() {
    let home = scratch();
    // A regular file where the config dir belongs: create_dir_all cannot pass.
    std::fs::write(home.join(".claude"), "not a directory").unwrap();

    let out = install(&home);
    assert_eq!(out.code(), Some(1));
    assert!(out.stderr.contains(".claude"), "the failure must name the path: {}", out.stderr);
    assert!(
        codex_skill(&home).exists(),
        "codex must still be installed when claude-code fails"
    );
}

#[test]
fn skill_usage_errors_exit_two() {
    let home = scratch();
    for args in [
        vec!["frobnicate"],
        vec!["install", "--target", "cursor"],
        vec!["install", "--scope", "system"],
        vec!["install", "--target"],
        vec!["install", "extra"],
    ] {
        let out = Report::of(skill_in(&home).args(&args));
        assert_eq!(out.code(), Some(2), "skill {args:?} should be a usage error");
    }
}

#[test]
fn help_documents_the_skill_verb_too() {
    let out = Report::of(tarmac().arg("--help"));
    assert!(out.stdout.contains("tarmac skill"));
    assert!(out.stdout.contains("tarmac skill install"));
    // --help splices skill::USAGE; without this the interpolation could be
    // dropped and every other test would stay green.
    assert!(out.stdout.contains("--dry-run"), "--help must carry install's flags");
}
