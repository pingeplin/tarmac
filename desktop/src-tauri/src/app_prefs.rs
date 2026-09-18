//! The app's own tiny preference file (spec 2609.0016, issue #171).
//!
//! It lives beside the daemon socket, the way `bridge.rs`'s `daemon_log_path`
//! does, so the dev and installed apps cannot share one: `<worktree>/.dev/`
//! under `make run`, the per-channel support dir otherwise. Tauri's
//! `app_config_dir()` resolves from the bundle identifier and would be the
//! same path for both.
//!
//! Anything unreadable means the guard is ON. A preference file is never a
//! reason to quit the cockpit by accident.

use std::path::{Path, PathBuf};

pub const PREFS_FILE: &str = "app-prefs.json";
const WARN_KEY: &str = "warn_before_quit";

pub fn prefs_path(socket: &Path) -> PathBuf {
    socket.parent().unwrap_or(Path::new(".")).join(PREFS_FILE)
}

/// Whether ⌘Q is guarded, as the file says. Missing, unreadable, malformed or
/// the wrong type all read as `true`.
pub fn warn_before_quit(contents: Option<&[u8]>) -> bool {
    let Some(bytes) = contents else { return true };
    serde_json::from_slice::<serde_json::Value>(bytes)
        .ok()
        .and_then(|v| v.get(WARN_KEY).and_then(serde_json::Value::as_bool))
        .unwrap_or(true)
}

pub fn encode_prefs(warn_before_quit: bool) -> Vec<u8> {
    format!("{{\"{WARN_KEY}\":{warn_before_quit}}}").into_bytes()
}

/// Read the toggle. Any IO failure is the same answer as an absent file.
pub fn load(path: &Path) -> bool {
    warn_before_quit(std::fs::read(path).ok().as_deref())
}

/// Save the toggle through a temp file, so a crash mid-write cannot leave a
/// half-written file that would then read as "guard on" forever. Best effort:
/// the in-memory toggle is what this session obeys either way.
pub fn save(path: &Path, warn_before_quit: bool) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, encode_prefs(warn_before_quit))?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// S24 — beside the socket, so `make run` keeps every worktree apart.
    #[test]
    fn the_prefs_file_sits_beside_the_daemon_socket() {
        assert_eq!(
            prefs_path(Path::new("/w/.dev/tarmacd.sock")),
            PathBuf::from("/w/.dev/app-prefs.json")
        );
    }

    /// S25 — every way of not saying "off" leaves the guard on.
    #[test]
    fn only_an_explicit_false_turns_the_guard_off() {
        for contents in [
            None,
            Some(&b"not json"[..]),
            Some(&b"{}"[..]),
            Some(&br#"{"warn_before_quit":"no"}"#[..]),
            Some(&br#"[false]"#[..]),
            Some(&br#"{"warn_before_quit":true}"#[..]),
        ] {
            assert!(warn_before_quit(contents), "contents {contents:?}");
        }
        assert!(!warn_before_quit(Some(br#"{"warn_before_quit":false}"#)));
        assert!(!warn_before_quit(Some(br#"{"warn_before_quit":false,"later":1}"#)));
    }

    /// S26 — the bytes QA reads in `.dev/app-prefs.json`, and the round trip.
    #[test]
    fn the_saved_bytes_are_exact_and_read_back() {
        assert_eq!(encode_prefs(false), br#"{"warn_before_quit":false}"#);
        assert_eq!(encode_prefs(true), br#"{"warn_before_quit":true}"#);
        assert!(!warn_before_quit(Some(&encode_prefs(false))));
        assert!(warn_before_quit(Some(&encode_prefs(true))));
    }
}
