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
