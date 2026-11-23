//! Test helpers that the inline tests of more than one module share.

use std::ffi::OsString;
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

/// One row of a section of `tarmac-protocol`'s
/// `tests/fixtures/socket_path_cases.json`, the table the Swift
/// `ChannelPathsTests` run too.
#[derive(Debug)]
pub(crate) struct SocketRow {
    env: serde_json::Value,
    pub(crate) channel: tarmac_protocol::Channel,
    pub(crate) path: String,
}

impl SocketRow {
    pub(crate) fn var(&self, name: &str) -> Option<OsString> {
        self.env.get(name).map(|v| OsString::from(v.as_str().unwrap()))
    }
}

/// The rows of `section`, which has a row in each channel.
pub(crate) fn socket_rows(section: &str) -> Vec<SocketRow> {
    use tarmac_protocol::Channel;
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tarmac-protocol/tests/fixtures/socket_path_cases.json");
    let table: serde_json::Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    let row = |row: &serde_json::Value| SocketRow {
        env: row["env"].clone(),
        channel: match row["channel"].as_str() {
            Some("dev") => Channel::Dev,
            Some("release") => Channel::Release,
            other => panic!("no channel {other:?}"),
        },
        path: row["path"].as_str().unwrap().to_owned(),
    };
    let rows: Vec<SocketRow> = table[section].as_array().unwrap().iter().map(row).collect();
    assert!([Channel::Dev, Channel::Release].iter().all(|c| rows.iter().any(|row| row.channel == *c)), "{section}");
    rows
}
