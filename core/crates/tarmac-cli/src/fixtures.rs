//! Test helpers that the inline tests of more than one module share.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

pub(crate) fn args(a: &[&str]) -> Vec<String> {
    a.iter().map(ToString::to_string).collect()
}

static DIR_SEQ: AtomicU64 = AtomicU64::new(0);

/// A new empty temp dir, named so that tests running at once cannot collide.
pub(crate) fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "tarmac-cli-unit-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}
