//! Wire types, codec, and framing for the tarmac unix-socket protocol.
//! Authoritative contract: docs/protocol.md.

mod channel;
pub mod dev;
pub mod frame;

pub use channel::{
    channel_dir, channel_label, check_socket_path_len, resolve_socket_path, resolve_state_path,
    Channel,
};

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

// No `Eq` on Msg, Tile or BoardViewport: their geometry fields are f64.
//
// Optional keys are additive: a missing key decodes to `None`, and `None` is
// omitted on encode, so frames from senders that predate a key stay byte-identical.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Msg {
    Hello {
        role: String,
        v: u32,
        /// Set by the app only; the CLI never sends it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_version: Option<String>,
    },
    HelloOk {
        v: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        daemon_version: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        daemon_pid: Option<u32>,
        /// `app_version` and `app_connected` go to `cli` clients only. They are
        /// separate because presence and version are separate facts:
        /// `app_connected: true` with no `app_version` is an app that named no
        /// version, which must not be reported as no app.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_version: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        app_connected: Option<bool>,
    },
    Ack,
    Err {
        msg: String,
    },
    Open {
        path: String,
        /// The terminal that ran `tarmac open`, which the CLI reads from
        /// `TARMAC_TERM_ID`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
        /// Explicit target board. Missing => the caller terminal's board, else
        /// the active one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
    },
    DocRead {
        path: String,
    },
    Layout {
        dock: Vec<String>,
        tiles: Vec<Tile>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board: Option<BoardViewport>,
        /// Missing => the active board.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
    },
    Restore {
        docs: Vec<DocEntry>,
        #[serde(default)]
        tiles: Vec<Tile>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board: Option<BoardViewport>,
        /// The daemon stamps the restored board's id so the app binds a restore
        /// unambiguously across rapid board switches.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
        /// Terminals with a live pty on this board; the app re-binds their cards
        /// to the running shells. Empty => cold-spawn.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        live_terms: Vec<String>,
    },
    SpawnTerm {
        term_id: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        cmd: Option<Vec<String>>,
        /// Missing or unknown => the active board.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
        /// The terminal whose live cwd (not its spawn cwd) the new one starts in.
        /// Ignored when `cwd` is set; an unknown or dead source falls through to
        /// the daemon's default.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        inherit_cwd_from: Option<String>,
    },
    Input {
        term_id: String,
        #[serde(with = "serde_bytes")]
        bytes: Vec<u8>,
    },
    Output {
        term_id: String,
        #[serde(with = "serde_bytes")]
        bytes: Vec<u8>,
    },
    Resize {
        term_id: String,
        cols: u16,
        rows: u16,
    },
    Exit {
        term_id: String,
        code: Option<i64>,
    },
    DocOpened(DocEntry),
    FileEvent {
        path: String,
        mtime_ms: u64,
    },
    TermProc {
        term_id: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<i64>,
    },
    Bell {
        term_id: String,
    },
    /// Daemon -> app: every board in display order, plus the active one.
    BoardList {
        boards: Vec<BoardMeta>,
        active: String,
    },
    /// App -> daemon: make `board_id` active; the daemon replies with its restore.
    BoardSwitch {
        board_id: String,
    },
    /// App -> daemon: mint a board; the daemon assigns the slug id.
    BoardCreate,
    /// App -> daemon: an empty `name` clears the display name back to the slug.
    BoardRename {
        board_id: String,
        name: String,
    },
    /// App -> daemon: refused when it is the last board.
    BoardDelete {
        board_id: String,
    },
    /// App -> daemon: kill one terminal's pty. An unknown `term_id` is a no-op.
    TermClose {
        term_id: String,
    },
    /// App -> daemon: forget a doc. Idempotent: an unknown path is a no-op.
    DocClose {
        path: String,
    },
    /// App -> daemon: re-stat a doc now and push the usual `file_event`.
    DocRefresh {
        path: String,
    },
    /// App -> daemon: re-emit one terminal's scrollback. An unknown `term_id` is
    /// not an error; see `Scrollback`.
    ScrollbackRequest {
        term_id: String,
    },
    /// Daemon -> app: the answer to exactly one `ScrollbackRequest`. Always sent,
    /// even for an empty ring or an unknown terminal, so the app never waits forever.
    Scrollback {
        term_id: String,
        #[serde(with = "serde_bytes")]
        bytes: Vec<u8>,
    },
    /// A receiver ignores message types it does not know instead of failing.
    #[serde(other)]
    Unknown,
}

/// One board's identity for the switcher. Display order is the vec order.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct BoardMeta {
    pub board_id: String,
    /// User-given display name; the switcher falls back to the slug `board_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Count of live ptys on the board, which the app cannot derive for a board
    /// it never opened. Missing => unknown, which is distinct from `Some(0)`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running: Option<u32>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct DocEntry {
    pub path: String,
    pub via: String,
    pub repo: Option<String>,
    pub repo_root: Option<String>,
    pub repo_color: Option<u8>,
    /// The wire default is true: an entry without the key never shows an unread dot.
    #[serde(default = "read_default")]
    pub read: bool,
    pub last_changed_ms: Option<u64>,
    pub last_opened_ms: Option<u64>,
    /// The terminal that opened the doc.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_id: Option<String>,
}

fn read_default() -> bool {
    true
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Default)]
pub struct Tile {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// World-space card frame and stacking order. The app places a tile that has
    /// none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub w: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub h: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub z: Option<i64>,
    /// Detached from its terminal's gravity; missing => attached.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loose: Option<bool>,
    /// From the removed shelf; the app drops such tiles. Kept for wire compatibility.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shelf: Option<bool>,
    /// The terminal a term tile belongs to. Absent on doc tiles and on legacy
    /// single-terminal layouts, which the daemon keeps as one `None`-keyed tile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_id: Option<String>,
}

/// The persisted board viewport: zoom factor and world-space center.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BoardViewport {
    pub zoom: f64,
    pub cx: f64,
    pub cy: f64,
}

/// FNV-1a 64-bit over the repo name, mod 4 => palette index 0..=3.
/// The only source of a doc's repo color: the app hashes nothing and maps the
/// index onto its palette, so changing the hash alters colors users already saw.
pub fn repo_color_index(repo: &str) -> u8 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in repo.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    (hash % 4) as u8
}

// to_vec_named is load-bearing: plain to_vec emits structs as msgpack arrays,
// violating the "map with string keys" rule.
pub fn encode(msg: &Msg) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(msg)
}

pub fn decode(bytes: &[u8]) -> Result<Msg, rmp_serde::decode::Error> {
    rmp_serde::from_slice(bytes)
}

#[cfg(test)]
mod tests;
