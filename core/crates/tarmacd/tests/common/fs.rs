use std::io::Write;
use std::path::Path;
use std::time::{Duration, UNIX_EPOCH};

/// `path`, made, as `pid_cwd` and `pwd -P` give it (a temp dir under `/var`
/// is `/private/var`).
pub fn canon_dir(path: &Path) -> String {
    std::fs::create_dir_all(path).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

pub fn write_doc(path: &Path, content: &str) -> String {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, content).unwrap();
    std::fs::canonicalize(path).unwrap().to_string_lossy().into_owned()
}

/// Appends `bytes`, which bumps the mtime and produces a watcher event.
pub fn append_to(path: impl AsRef<Path>, bytes: &[u8]) {
    let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    f.write_all(bytes).unwrap();
    f.sync_all().unwrap();
}

pub fn touch(path: impl AsRef<Path>) {
    append_to(path, b"\n");
}

/// `touch`, and the mtime the file has after it.
pub fn edit(path: impl AsRef<Path>) -> u64 {
    touch(&path);
    mtime_ms(path)
}

/// The file's mtime, truncated exactly as the daemon truncates it for a file_event.
#[expect(clippy::cast_possible_truncation, reason = "predates the lint; decided in #470")]
pub fn mtime_ms(path: impl AsRef<Path>) -> u64 {
    std::fs::metadata(path).unwrap().modified().unwrap().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// Lets the watcher go quiet before an edit: a watch that was just attached, or
/// events that are still in flight.
pub fn settle() {
    std::thread::sleep(Duration::from_millis(300));
}
