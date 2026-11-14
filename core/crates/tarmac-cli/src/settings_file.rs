//! Another program's JSON settings file, read and rewritten in place. A write
//! keeps the key order, the indent and the final newline, backs the old bytes
//! up beside the file, goes through a symlink to its target, keeps the mode,
//! and is atomic. What the file must hold is the caller's business.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::ser::{PrettyFormatter, Serializer};
use serde_json::{Value, json};

/// A settings file as read.
pub(crate) struct SettingsFile {
    /// The file that a write replaces: the target, when the path is a symlink.
    pub(crate) real: PathBuf,
    /// The text, or `None` for a file that does not exist yet.
    pub(crate) original: Option<String>,
    pub(crate) root: Value,
}

/// Reads and parses `path`; a missing file is `{}`. A symlink whose target is
/// missing is refused, so that a write never makes a file somewhere else.
pub(crate) fn load(path: &Path) -> Result<SettingsFile, String> {
    let real = match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            fs::canonicalize(path).map_err(|e| format!("a symlink whose target cannot be read ({e})"))?
        }
        _ => path.to_path_buf(),
    };
    let bytes = match fs::read(&real) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(SettingsFile { real, original: None, root: json!({}) });
        }
        Err(e) => return Err(format!("cannot read it ({e})")),
    };
    let text = String::from_utf8(bytes).map_err(|_| "it is not UTF-8".to_string())?;
    if text.is_empty() {
        return Err("the file is empty, and an empty file is not JSON".into());
    }
    if text.starts_with('\u{feff}') {
        return Err("the file starts with a BOM, which JSON does not allow".into());
    }
    let root = serde_json::from_str(&text).map_err(|e| format!("it is not valid JSON ({e})"))?;
    Ok(SettingsFile { real, original: Some(text), root })
}

pub(crate) fn backup_path(real: &Path) -> PathBuf {
    with_suffix(real, ".tarmac-backup")
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// Writes `file.root` over the real file, and returns the backup of the old
/// one. A file that cannot be written is refused before anything is made.
pub(crate) fn write(file: &SettingsFile) -> Result<Option<PathBuf>, String> {
    let real = &file.real;
    let text = render(&file.root, file.original.as_deref());
    let cannot_write = |e: io::Error| format!("cannot write it ({e})");
    let Some(original) = &file.original else {
        let dir = real.parent().ok_or("it has no parent directory")?;
        fs::create_dir_all(dir).map_err(|e| format!("cannot create {} ({e})", dir.display()))?;
        replace(&tmp_path(real)?, real, text.as_bytes(), None).map_err(cannot_write)?;
        return Ok(None);
    };
    let mode = probe(real).map_err(cannot_write)?;
    let backup = backup_path(real);
    replace(&with_suffix(&backup, "-tmp"), &backup, original.as_bytes(), Some(mode)).map_err(cannot_write)?;
    replace(&tmp_path(real)?, real, text.as_bytes(), Some(mode)).map_err(cannot_write)?;
    Ok(Some(backup))
}

/// `.<name>.tarmac-tmp` beside `real`.
fn tmp_path(real: &Path) -> Result<PathBuf, String> {
    let mut name = std::ffi::OsString::from(".");
    name.push(real.file_name().ok_or("it has no file name")?);
    name.push(".tarmac-tmp");
    Ok(real.with_file_name(name))
}

/// The mode of the existing file, once it opens for writing: a rename alone
/// would replace a read-only file in a writable directory.
fn probe(real: &Path) -> io::Result<u32> {
    OpenOptions::new().write(true).open(real)?;
    Ok(fs::metadata(real)?.permissions().mode())
}

/// Puts `bytes` at `dest` through a new `tmp` and a rename. `tmp` is made with
/// O_EXCL and the rename replaces a symlink at `dest`, so nothing planted at
/// either path is written through. With `mode` the file is never briefly
/// wider than it; without, it gets the default mode.
fn replace(tmp: &Path, dest: &Path, bytes: &[u8], mode: Option<u32>) -> io::Result<()> {
    let _ = fs::remove_file(tmp);
    let mut file = OpenOptions::new().write(true).create_new(true).mode(mode.map_or(0o666, |_| 0o600)).open(tmp)?;
    let written = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        if let Some(mode) = mode {
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        fs::rename(tmp, dest)
    })();
    if written.is_err() {
        let _ = fs::remove_file(tmp);
    }
    written
}

/// The indent of the file's first indented line: a tab, or that many spaces.
/// Two spaces, Claude Code's own, when no line is indented.
fn indent_unit(text: &str) -> String {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .find_map(|line| match line.as_bytes().first() {
            Some(b'\t') => Some("\t".to_string()),
            Some(b' ') => Some(" ".repeat(line.len() - line.trim_start_matches(' ').len())),
            _ => None,
        })
        .unwrap_or_else(|| "  ".to_string())
}

/// `root` as the file's new text, in the original's indent and final newline.
pub(crate) fn render(root: &Value, original: Option<&str>) -> String {
    let unit = original.map_or_else(|| "  ".to_string(), indent_unit);
    let mut out = Vec::new();
    let mut ser = Serializer::with_formatter(&mut out, PrettyFormatter::with_indent(unit.as_bytes()));
    root.serialize(&mut ser).expect("a Value always serializes");
    if original.is_none_or(|o| o.ends_with('\n')) {
        out.push(b'\n');
    }
    String::from_utf8(out).expect("serde_json writes UTF-8")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_indent_is_the_first_indented_lines() {
        assert_eq!(indent_unit("{\n  \"a\": {\n    \"b\": 1\n  }\n}\n"), "  ");
        assert_eq!(indent_unit("{\n    \"a\": 1\n}"), "    ");
        assert_eq!(indent_unit("{\n\t\"a\": 1\n}\n"), "\t");
        assert_eq!(indent_unit("{}"), "  ");
        assert_eq!(indent_unit("{\"a\": 1}\n"), "  ");
    }

    #[test]
    fn render_keeps_a_missing_final_newline_and_ends_a_new_file_with_one() {
        let root = json!({"a": [1]});
        assert_eq!(render(&root, Some("{\n    \"a\": []\n}")), "{\n    \"a\": [\n        1\n    ]\n}");
        assert_eq!(render(&root, None), "{\n  \"a\": [\n    1\n  ]\n}\n");
    }
}
