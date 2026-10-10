//! Wire types for the in-app QA driver, a debug-build side channel. They are
//! deliberately not `Msg` variants: the main protocol is additive-only, so
//! anything added there would be permanent.

use crate::channel::resolve;
use crate::Channel;
use serde::{Deserialize, Serialize};
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;

/// Tagged like `Msg`: `"t"` names the verb in snake_case.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum DevRequest {
    Snapshot {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        until: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u32>,
    },
    Zoom {
        z: f64,
    },
    /// `card: None` is the board background, which is what blurs a focused
    /// terminal. Card ids are never the literal "board" (they are term ids or
    /// absolute paths), so the absence carries the meaning with no sentinel.
    Focus {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        card: Option<String>,
    },
    Resize {
        card: String,
        w: f64,
        h: f64,
    },
    Type {
        card: String,
        text: String,
    },
    Key {
        card: String,
        combo: String,
    },
    /// A native ⌘ chord, posted in-process. The app parses `combo`; the CLI only
    /// checks the flags' ranges.
    Press {
        combo: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hold_ms: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        age_ms: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        busy_ms: Option<u32>,
    },
    /// Decoding an unknown verb to a value rather than an error lets the app
    /// answer "unsupported" instead of dropping the frame.
    #[serde(other)]
    Unknown,
}

/// The only definition of `press`'s flag ranges: `--hold` is `1..=HOLD_MS_MAX`,
/// `--age` is `0..=AGE_MS_MAX`, `--busy` is `1..=BUSY_MS_MAX`. `BUSY_MS_MAX` sits
/// below the guard's 2000 ms freshness bound: past it a frozen page's ⌘Q routes
/// `terminate` and really quits.
pub const HOLD_MS_MAX: u32 = 10_000;
pub const AGE_MS_MAX: u32 = 60_000;
pub const BUSY_MS_MAX: u32 = 1_800;

impl DevRequest {
    /// The caller's own wait budget, where the verb has one: `snapshot` carries
    /// its `--timeout`, `press` its `--busy` (the page answers only once the
    /// freeze ends). Every other wait fits in the backend's fixed slack. It lives
    /// on the type because both ends of the socket need the rule.
    pub fn timeout_ms(&self) -> Option<u32> {
        match self {
            DevRequest::Snapshot { timeout_ms, .. } => *timeout_ms,
            DevRequest::Press { busy_ms, .. } => *busy_ms,
            _ => None,
        }
    }
}

/// `body` is an opaque string the CLI prints verbatim and never parses, which
/// keeps `tarmac-cli` std-only.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct DevReply {
    pub ok: bool,
    pub body: String,
}

// to_vec_named, as in the main codec: plain to_vec emits structs as arrays.
pub fn encode_request(req: &DevRequest) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(req)
}

pub fn decode_request(bytes: &[u8]) -> Result<DevRequest, rmp_serde::decode::Error> {
    rmp_serde::from_slice(bytes)
}

pub fn encode_reply(reply: &DevReply) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(reply)
}

pub fn decode_reply(bytes: &[u8]) -> Result<DevReply, rmp_serde::decode::Error> {
    rmp_serde::from_slice(bytes)
}

/// `over` is `TARMAC_DEV_SOCKET`.
pub fn resolve_dev_socket_path(over: Option<OsString>, home: &OsStr, channel: Channel) -> PathBuf {
    resolve(over, home, channel, "tarmac-dev.sock")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{channel_dir, resolve_socket_path};
    use std::path::Path;

    fn roundtrip(req: &DevRequest) -> DevRequest {
        decode_request(&encode_request(req).unwrap()).unwrap()
    }

    /// Every variant survives encode -> decode.
    #[test]
    fn every_dev_request_variant_roundtrips() {
        let all = [
            DevRequest::Snapshot { until: None, timeout_ms: None },
            DevRequest::Snapshot {
                until: Some("cards[t-1].term.cols != 80".into()),
                timeout_ms: Some(1500),
            },
            DevRequest::Zoom { z: 0.5 },
            DevRequest::Focus { card: Some("t-1".into()) },
            DevRequest::Focus { card: None },
            DevRequest::Resize { card: "t-1".into(), w: 800.0, h: 600.0 },
            DevRequest::Type { card: "t-1".into(), text: "a\nb".into() },
            DevRequest::Key { card: "t-1".into(), combo: "ctrl+c".into() },
        ];
        for req in all {
            assert_eq!(roundtrip(&req), req, "roundtrip changed {req:?}");
        }
    }

    /// The encoding is a msgpack MAP, not an array. This is the one
    /// assertion that catches plain `to_vec`, which the wire contract forbids.
    #[test]
    fn dev_frames_encode_as_maps_not_arrays() {
        for bytes in [
            encode_request(&DevRequest::Zoom { z: 1.0 }).unwrap(),
            encode_request(&DevRequest::Focus { card: None }).unwrap(),
            encode_reply(&DevReply { ok: true, body: "{}".into() }).unwrap(),
        ] {
            let head = bytes[0];
            let is_map = (0x80..=0x8f).contains(&head) || head == 0xde || head == 0xdf;
            assert!(is_map, "expected a msgpack map, first byte was {head:#04x}");
        }
    }

    /// The tag key is "t" and the tag value is snake_case, mirroring `Msg`,
    /// so one reader convention covers both sockets.
    #[test]
    fn dev_requests_are_tagged_like_msg() {
        // Read the tag by KEY NAME. A substring check for "t" would be
        // satisfied by the tag *value* ("snapsho-t-") and could never fail;
        // this deserialize fails if the key is named anything but `t`.
        #[derive(serde::Deserialize)]
        struct Tag {
            t: String,
        }
        let tag_of = |req| rmp_serde::from_slice::<Tag>(&encode_request(&req).unwrap()).unwrap().t;
        assert_eq!(tag_of(DevRequest::Snapshot { until: None, timeout_ms: None }), "snapshot");
        assert_eq!(tag_of(DevRequest::Type { card: "t-1".into(), text: "x".into() }), "type");
        assert_eq!(tag_of(DevRequest::Focus { card: None }), "focus");
    }

    /// Additive-only: an unknown key on a known request is ignored.
    #[test]
    fn unknown_keys_are_ignored() {
        // A `zoom` request from a newer CLI that also sends an `anchor` key.
        #[derive(serde::Serialize)]
        struct Future<'a> { t: &'a str, z: f64, anchor: &'a str }
        let bytes = rmp_serde::to_vec_named(&Future { t: "zoom", z: 0.5, anchor: "pointer" }).unwrap();
        assert_eq!(decode_request(&bytes).unwrap(), DevRequest::Zoom { z: 0.5 });
    }

    /// An unknown request TYPE decodes to `Unknown` rather than failing,
    /// so an older app can refuse a newer verb instead of dropping the frame.
    #[test]
    fn unknown_request_types_decode_to_unknown() {
        #[derive(serde::Serialize)]
        struct Future<'a> { t: &'a str }
        let bytes = rmp_serde::to_vec_named(&Future { t: "teleport" }).unwrap();
        assert_eq!(decode_request(&bytes).unwrap(), DevRequest::Unknown);
    }

    /// Every `Press` shape round-trips under the `press` tag, and absent flags
    /// are absent keys, not nils.
    #[test]
    fn press_roundtrips_and_skips_absent_flags() {
        let bare = DevRequest::Press { combo: "cmd+q".into(), hold_ms: None, age_ms: None, busy_ms: None };
        let all = [
            bare.clone(),
            DevRequest::Press { combo: "cmd+q".into(), hold_ms: Some(1000), age_ms: None, busy_ms: None },
            DevRequest::Press { combo: "cmd+q".into(), hold_ms: None, age_ms: Some(2500), busy_ms: None },
            DevRequest::Press { combo: "alt+cmd+q".into(), hold_ms: Some(10000), age_ms: Some(0), busy_ms: None },
            DevRequest::Press { combo: "nonsense".into(), hold_ms: None, age_ms: None, busy_ms: None },
            DevRequest::Press { combo: "cmd+q".into(), hold_ms: None, age_ms: None, busy_ms: Some(1000) },
        ];
        for req in all {
            assert_eq!(roundtrip(&req), req, "roundtrip changed {req:?}");
        }
        #[derive(serde::Deserialize)]
        struct Tag {
            t: String,
        }
        let bytes = encode_request(&bare).unwrap();
        assert_eq!(rmp_serde::from_slice::<Tag>(&bytes).unwrap().t, "press");
        let keys: std::collections::BTreeMap<String, serde::de::IgnoredAny> =
            rmp_serde::from_slice(&bytes).unwrap();
        assert_eq!(keys.keys().cloned().collect::<Vec<_>>(), ["combo", "t"]);
    }

    /// `press` carries its `--busy` as its budget, so both ends of the socket
    /// wait out the freeze.
    #[test]
    fn press_budget_is_its_busy_ms() {
        let press = |busy_ms| DevRequest::Press { combo: "cmd+q".into(), hold_ms: None, age_ms: None, busy_ms };
        assert_eq!(press(Some(1000)).timeout_ms(), Some(1000));
        assert_eq!(press(None).timeout_ms(), None);
    }

    /// Additive-only holds for `press` too.
    #[test]
    fn unknown_keys_on_press_are_ignored() {
        #[derive(serde::Serialize)]
        struct Future<'a> { t: &'a str, combo: &'a str, hold_ms: u32, pressure: u32 }
        let bytes = rmp_serde::to_vec_named(&Future { t: "press", combo: "cmd+q", hold_ms: 1, pressure: 5 }).unwrap();
        assert_eq!(
            decode_request(&bytes).unwrap(),
            DevRequest::Press { combo: "cmd+q".into(), hold_ms: Some(1), age_ms: None, busy_ms: None },
        );
    }

    /// `body` is opaque: it survives byte-for-byte, JSON or not.
    #[test]
    fn reply_body_survives_verbatim() {
        for body in ["{\"v\":1}", "not json at all", "two\nlines", ""] {
            let reply = DevReply { ok: false, body: body.into() };
            let back = decode_reply(&encode_reply(&reply).unwrap()).unwrap();
            assert_eq!(back, reply);
        }
    }

    /// The default path per channel.
    #[test]
    fn dev_socket_defaults_per_channel() {
        let home = Path::new("/Users/x");
        assert_eq!(
            resolve_dev_socket_path(None, home.as_os_str(), Channel::Dev),
            Path::new("/Users/x/Library/Application Support/tarmac/dev/tarmac-dev.sock"),
        );
        assert_eq!(
            resolve_dev_socket_path(None, home.as_os_str(), Channel::Release),
            Path::new("/Users/x/Library/Application Support/tarmac/tarmac-dev.sock"),
        );
    }

    /// TARMAC_DEV_SOCKET wins verbatim in both channels; empty means unset.
    #[test]
    fn dev_socket_override_wins_and_empty_means_unset() {
        let home = std::ffi::OsStr::new("/Users/x");
        for channel in [Channel::Release, Channel::Dev] {
            assert_eq!(
                resolve_dev_socket_path(Some(OsString::from("/tmp/x.sock")), home, channel),
                Path::new("/tmp/x.sock"),
            );
            assert_eq!(
                resolve_dev_socket_path(Some(OsString::new()), home, channel),
                resolve_dev_socket_path(None, home, channel),
            );
        }
    }

    /// The dev socket shares `channel_dir` with the daemon socket, so the
    /// `dev` path literal cannot drift into a second definition.
    #[test]
    fn dev_socket_shares_the_channel_dir() {
        let home = std::ffi::OsStr::new("/Users/x");
        for channel in [Channel::Release, Channel::Dev] {
            let dev = resolve_dev_socket_path(None, home, channel);
            assert_eq!(dev.parent().unwrap(), channel_dir(Path::new(home), channel));
            assert_eq!(
                dev.parent(),
                resolve_socket_path(None, home, channel).parent(),
            );
            assert_eq!(dev.file_name().unwrap(), "tarmac-dev.sock");
        }
    }
}
