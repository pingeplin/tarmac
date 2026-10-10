//! Per-channel daemon socket and state path derivation, shared by `tarmacd`
//! and the CLI so the `dev` path segment is defined once. The Swift app mirrors
//! it in `ChannelPaths`.

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// `Release` is the shipped bundle (`cfg!(debug_assertions) == false`); `Dev` is
/// any debug build. Each binary maps its own build configuration to this enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    Release,
    Dev,
}

/// `<home>/Library/Application Support/tarmac`, plus `/dev` for `Dev`. Every
/// default path derives from this, so socket and state always share a channel.
pub fn channel_dir(home: &Path, channel: Channel) -> PathBuf {
    let base = home.join("Library/Application Support/tarmac");
    match channel {
        Channel::Release => base,
        Channel::Dev => base.join("dev"),
    }
}

/// A non-empty `over` (the env var's value) wins verbatim; empty means unset.
/// Otherwise `file_name` lives in the channel directory.
pub(crate) fn resolve(over: Option<OsString>, home: &OsStr, channel: Channel, file_name: &str) -> PathBuf {
    match over.filter(|v| !v.is_empty()) {
        Some(p) => PathBuf::from(p),
        None => channel_dir(Path::new(home), channel).join(file_name),
    }
}

/// `over` is `TARMAC_SOCKET`. `Release` resolves to the original flat path, so
/// existing users are never migrated.
pub fn resolve_socket_path(over: Option<OsString>, home: &OsStr, channel: Channel) -> PathBuf {
    resolve(over, home, channel, "tarmacd.sock")
}

/// `over` is `TARMAC_STATE`; used by `tarmacd` only.
pub fn resolve_state_path(over: Option<OsString>, home: &OsStr, channel: Channel) -> PathBuf {
    resolve(over, home, channel, "state.json")
}

/// macOS caps `sockaddr_un.sun_path` at 104 bytes and bind/connect fail opaquely
/// past it, so a path of 104 bytes or more is rejected with the remedy.
pub fn check_socket_path_len(path: &Path) -> Result<(), String> {
    let len = path.as_os_str().len();
    if len < 104 {
        Ok(())
    } else {
        Err(format!(
            "socket path is {} bytes, over the 104-byte macOS sockaddr_un.sun_path cap: {}; \
             set TARMAC_SOCKET to a shorter path, e.g. under /tmp",
            len,
            path.display()
        ))
    }
}

/// Mirrors Swift `ChannelPaths.channelLabel`.
pub fn channel_label(channel: Channel) -> &'static str {
    match channel {
        Channel::Release => "release",
        Channel::Dev => "dev",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn os(s: &str) -> OsString {
        OsString::from(s)
    }

    #[test]
    fn resolve_socket_path_cases() {
        let cases: &[(Option<&str>, &str, Channel, &str)] = &[
            // release is the legacy flat path, byte-for-byte
            (None, "/Users/eplin", Channel::Release,
             "/Users/eplin/Library/Application Support/tarmac/tarmacd.sock"),
            // dev inserts exactly the `dev/` segment
            (None, "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/tarmacd.sock"),
            (Some("/tmp/x.sock"), "/Users/eplin", Channel::Release, "/tmp/x.sock"),
            // the override wins even in dev: the integration harness injects
            // TARMAC_SOCKET into debug builds and must bypass the `dev/` segment
            (Some("/tmp/x.sock"), "/Users/eplin", Channel::Dev, "/tmp/x.sock"),
            // an empty override is treated as unset
            (Some(""), "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/tarmacd.sock"),
        ];
        for (over, home, channel, expected) in cases {
            assert_eq!(
                resolve_socket_path(over.map(os), OsStr::new(home), *channel),
                PathBuf::from(expected),
                "resolve_socket_path(over={over:?}, home={home:?}, {channel:?})"
            );
        }
    }

    // dev differs from release only by the inserted `/dev` segment.
    #[test]
    fn dev_differs_from_release_only_by_segment() {
        let home = OsStr::new("/Users/eplin");
        let release = resolve_socket_path(None, home, Channel::Release);
        let dev = resolve_socket_path(None, home, Channel::Dev);
        let expected = release
            .to_str()
            .unwrap()
            .replace("/tarmacd.sock", "/dev/tarmacd.sock");
        assert_eq!(dev.to_str().unwrap(), expected);
    }

    #[test]
    fn resolve_state_path_cases() {
        let cases: &[(Option<&str>, &str, Channel, &str)] = &[
            (None, "/Users/eplin", Channel::Release,
             "/Users/eplin/Library/Application Support/tarmac/state.json"),
            // state carries the same `dev/` segment as the socket
            (None, "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/state.json"),
            (Some("/tmp/s.json"), "/Users/eplin", Channel::Dev, "/tmp/s.json"),
            (Some(""), "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/state.json"),
        ];
        for (over, home, channel, expected) in cases {
            assert_eq!(
                resolve_state_path(over.map(os), OsStr::new(home), *channel),
                PathBuf::from(expected),
                "resolve_state_path(over={over:?}, home={home:?}, {channel:?})"
            );
        }
    }

    // A dev daemon can never bind a dev socket while reading release state.
    #[test]
    fn state_and_socket_share_channel_dir() {
        let home = OsStr::new("/Users/eplin");
        for channel in [Channel::Release, Channel::Dev] {
            let sock = resolve_socket_path(None, home, channel);
            let state = resolve_state_path(None, home, channel);
            assert_eq!(
                sock.parent(),
                state.parent(),
                "socket and state must share the per-channel dir ({channel:?})"
            );
        }
    }

    // The dev default appends a fixed 52-byte suffix to `home`
    // (/Library/Application Support/tarmac/dev/tarmacd.sock), so a 51-byte home
    // gives 103 bytes (accepted by `len < 104`) and a 52-byte home gives 104.
    #[test]
    fn dev_socket_byte_boundary() {
        let home51 = format!("/{}", "a".repeat(50)); // 51 bytes
        assert_eq!(home51.len(), 51);
        assert_eq!(
            resolve_socket_path(None, OsStr::new(&home51), Channel::Dev).as_os_str().len(),
            103,
        );

        let home52 = format!("/{}", "a".repeat(51)); // 52 bytes
        assert_eq!(home52.len(), 52);
        assert_eq!(
            resolve_socket_path(None, OsStr::new(&home52), Channel::Dev).as_os_str().len(),
            104,
        );
    }

    // 103 bytes is the last accepted length; 104 (the sun_path cap) is rejected
    // with a message naming the cap and the TARMAC_SOCKET remedy.
    #[test]
    fn check_socket_path_len_boundary() {
        let path103 = PathBuf::from(format!("/{}", "a".repeat(102))); // "/" + 102 = 103
        assert_eq!(path103.as_os_str().len(), 103);
        assert!(
            check_socket_path_len(&path103).is_ok(),
            "103-byte path must be accepted"
        );

        let path104 = PathBuf::from(format!("/{}", "a".repeat(103))); // "/" + 103 = 104
        assert_eq!(path104.as_os_str().len(), 104);
        let err = check_socket_path_len(&path104);
        assert!(err.is_err(), "104-byte path must be rejected");

        let msg = err.unwrap_err();
        assert!(
            msg.contains("104"),
            "error message must contain \"104\", got: {msg}"
        );
        assert!(
            msg.contains("TARMAC_SOCKET"),
            "error message must contain \"TARMAC_SOCKET\", got: {msg}"
        );

        // over-cap: 150-byte path — cap literal "104" must still appear independently
        // of the interpolated length ("150").
        let path150 = PathBuf::from(format!("/{}", "a".repeat(149))); // "/" + 149 = 150
        assert_eq!(path150.as_os_str().len(), 150);
        let err150 = check_socket_path_len(&path150);
        assert!(err150.is_err(), "150-byte path must be rejected");
        let msg150 = err150.unwrap_err();
        assert!(
            msg150.contains("104"),
            "error message for 150-byte path must still contain \"104\", got: {msg150}"
        );
        assert!(
            msg150.contains("TARMAC_SOCKET"),
            "error message for 150-byte path must contain \"TARMAC_SOCKET\", got: {msg150}"
        );
    }

    // A swapped or constant label fails.
    #[test]
    fn channel_label_maps_both() {
        assert_eq!(channel_label(Channel::Release), "release");
        assert_eq!(channel_label(Channel::Dev), "dev");
    }
}
