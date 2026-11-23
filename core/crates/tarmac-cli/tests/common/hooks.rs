use std::path::{Path, PathBuf};
use std::process::Command;

use super::{scratch, tarmac};

/// A scratch dir in its canonical form, so a path the cli prints compares
/// equal to one the test builds (`/var` is `/private/var` on macOS), with the
/// `home` and `proj` dirs that `hooks_cmd` points at.
pub(crate) fn sandbox() -> PathBuf {
    let dir = scratch().canonicalize().unwrap();
    for sub in ["home", "proj"] {
        std::fs::create_dir_all(dir.join(sub)).unwrap();
    }
    dir
}

/// `tarmac hooks`, with `dir/home` as HOME, `dir/proj` as the cwd, an empty
/// CLAUDE_CONFIG_DIR (unset, so HOME decides) and no TARMAC_TERM_ID.
pub(crate) fn hooks_cmd(dir: &Path) -> Command {
    let mut cmd = tarmac();
    cmd.env("HOME", dir.join("home"))
        .env("CLAUDE_CONFIG_DIR", "")
        .env_remove("TARMAC_TERM_ID")
        .current_dir(dir.join("proj"))
        .arg("hooks");
    cmd
}

pub(crate) fn fixture(name: &str) -> Vec<u8> {
    std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hooks").join(format!("{name}.json")))
        .unwrap()
}
