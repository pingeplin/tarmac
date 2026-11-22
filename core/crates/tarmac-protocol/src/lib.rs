//! Wire types, codec, and framing for the tarmac unix-socket protocol.
//! Authoritative contract: docs/protocol.md.

mod channel;
pub mod dev;
pub mod frame;

pub use channel::{
    Channel, channel_dir, channel_label, check_socket_path_len, resolve_socket_path, resolve_state_path,
};

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

/// How long the cli waits for the daemon's answer. A daemon that waits on
/// someone else for a cli (`term_new`) bounds that wait below it.
pub const DAEMON_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

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
        /// The board's record of each terminal, keyed by term id. A cold spawn
        /// of a persisted tile starts in its record's `last_cwd`.
        #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
        term_records: BTreeMap<String, TermRecord>,
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
        /// The persisted term id this terminal replaces: its record moves to
        /// the new `term_id`. Ignored for a live term, an id with no record,
        /// or a spawn that fails.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        succeeds: Option<String>,
    },
    Input {
        term_id: String,
        #[serde(with = "serde_bytes")]
        bytes: Vec<u8>,
        /// Input from the user's own key, paste, text or mouse report; only
        /// such input marks a report read. Sent only as `true`.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        typed: bool,
        /// Spec 2611.0016, D11: the daemon holds the bytes until the shell
        /// takes keys. Sent only as `true`.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        hold: bool,
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
        /// The board the terminal was filed under when it ended (2611.0013).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
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
        /// The board the terminal is filed under (2611.0013).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
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
    /// App -> daemon: the doc `path` on board `board_id` reads the data file
    /// `file`; `None` clears it. The daemon reports that file as it reports a
    /// doc, with a `file_event` for `file`.
    DataFile {
        board_id: String,
        path: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<String>,
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
    /// cli -> daemon: one JSON value for the loaded cards of the doc `path`;
    /// answered `ack` or `err`. `value` is the value's text, checked by the
    /// daemon only. Field order is wire order (vector 16).
    Push {
        path: String,
        value: String,
    },
    /// Daemon -> app: a `push`, with `path` the registry's key. No reply.
    DocEvent {
        path: String,
        value: String,
    },
    /// cli -> daemon: the terminal's report, `blocked`, `done` or `clear`;
    /// answered `ack` or `err`.
    Report {
        term_id: String,
        kind: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text: Option<String>,
    },
    /// Daemon -> app: a terminal's current report. No `kind` is no report.
    TermReport {
        term_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kind: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        text: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        at_ms: Option<u64>,
        /// The holder's process name, as the daemon read it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proc: Option<String>,
        /// The reverse of `DocEntry.read`: a missing key is unread.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        read: bool,
        /// The board the terminal is filed under, and its `last_cwd` record,
        /// when the report was made (2611.0013). Never on a frame with no `kind`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cwd: Option<String>,
    },
    /// cli -> daemon: the calling terminal's resume command (spec 2611.0011);
    /// no `cmd` clears it. Answered `ack` or `err`.
    Resume {
        term_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cmd: Option<String>,
    },
    /// Daemon -> app (spec 2611.0015): a live terminal's recorded resume
    /// command changed. No `cmd` is no command. Not a `subscribe` kind.
    TermResume {
        term_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cmd: Option<String>,
    },
    /// cli -> daemon (spec 2611.0012): the daemon's facts for a script. The
    /// reply is `err`, or the snapshot frames, `ack`, then the live `exit`,
    /// `bell`, `file_event` and `term_report` frames that pass the filter.
    /// `kinds` names `exit`, `bell`, `changed` or `report`; missing is all.
    Subscribe {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        kinds: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    /// cli -> daemon: the live terminals; answered `terms` or `err`.
    TermsList,
    /// Daemon -> cli: one row per live terminal, in board order, then by id.
    Terms {
        terms: Vec<TermInfo>,
    },
    /// cli -> daemon -> app (spec 2611.0016): a terminal card that types
    /// `cmd` into a login shell in `cwd`. The daemon numbers the request and
    /// names the board for the app; the cli sends neither.
    TermNew {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        req_id: Option<u64>,
        cmd: String,
        cwd: String,
        /// The calling terminal: the new card's owner, and its board.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
    },
    /// App -> daemon -> cli: the new terminal. Only the app's carries `req_id`.
    TermNewOk {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        req_id: Option<u64>,
        term_id: String,
    },
    /// App -> daemon: the request was refused; the cli gets `err`.
    TermNewErr {
        req_id: u64,
        msg: String,
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

/// The kinds of frame a `subscribe` names (spec 2611.0012), by the cli's
/// names on the wire in `kinds`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EventKind {
    Exit,
    Bell,
    Changed,
    Report,
}

impl EventKind {
    pub const ALL: [EventKind; 4] = [EventKind::Exit, EventKind::Bell, EventKind::Changed, EventKind::Report];

    pub fn name(self) -> &'static str {
        match self {
            EventKind::Exit => "exit",
            EventKind::Bell => "bell",
            EventKind::Changed => "changed",
            EventKind::Report => "report",
        }
    }

    pub fn named(name: &str) -> Option<EventKind> {
        EventKind::ALL.into_iter().find(|k| k.name() == name)
    }

    /// The kind of an event frame and its terminal, `None` for any other
    /// frame. A `file_event` has no terminal.
    pub fn of(msg: &Msg) -> Option<(EventKind, Option<&str>)> {
        match msg {
            Msg::Exit { term_id, .. } => Some((EventKind::Exit, Some(term_id))),
            Msg::Bell { term_id, .. } => Some((EventKind::Bell, Some(term_id))),
            Msg::FileEvent { .. } => Some((EventKind::Changed, None)),
            Msg::TermReport { term_id, .. } => Some((EventKind::Report, Some(term_id))),
            _ => None,
        }
    }

    /// True for an event frame of one of `kinds` and, with a `term_id`, of
    /// that terminal. A `file_event` has no terminal, so a terminal filter
    /// never admits one.
    pub fn admits(kinds: &[EventKind], term_id: Option<&str>, msg: &Msg) -> bool {
        let Some((kind, term)) = EventKind::of(msg) else { return false };
        kinds.contains(&kind) && term_id.is_none_or(|want| term == Some(want))
    }
}

/// The kind of a terminal's report (spec 2611.0009), by its name in the
/// `kind` of `report` and `term_report`. A `report` of `REPORT_CLEAR` clears
/// one and is no kind.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ReportKind {
    Blocked,
    Done,
}

pub const REPORT_CLEAR: &str = "clear";

impl ReportKind {
    pub const ALL: [ReportKind; 2] = [ReportKind::Blocked, ReportKind::Done];

    pub fn name(self) -> &'static str {
        match self {
            ReportKind::Blocked => "blocked",
            ReportKind::Done => "done",
        }
    }

    pub fn named(name: &str) -> Option<ReportKind> {
        ReportKind::ALL.into_iter().find(|k| k.name() == name)
    }
}

/// One live terminal in `terms`. `cwd` and `proc` are the daemon's fresh reads,
/// missing when it could not read them.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct TermInfo {
    pub term_id: String,
    pub board_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proc: Option<String>,
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
    /// A markdown card's sidebar width, world px (spec 2611.0024).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_w: Option<f64>,
    /// A markdown card's docked sidebar is open; missing => no choice yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sidebar_open: Option<bool>,
}

/// What the daemon keeps of one terminal across its restarts.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Default)]
pub struct TermRecord {
    /// The terminal's last cwd that the daemon read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_cwd: Option<String>,
    /// Set while the terminal's agent runs; kept when the daemon dies first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<ResumeRecord>,
}

/// The command that resumes the agent session last run in a terminal. No pid:
/// one from a dead daemon names no process.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct ResumeRecord {
    pub cmd: String,
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

/// The longest report text, in Unicode scalar values (`char`s).
pub const REPORT_TEXT_MAX: usize = 280;

/// `text`, or its first `REPORT_TEXT_MAX - 1` chars and `…` when it is longer.
/// The cli and the daemon both cap with it.
pub fn cap_report_text(text: &str) -> String {
    if text.chars().count() <= REPORT_TEXT_MAX {
        return text.to_owned();
    }
    text.chars().take(REPORT_TEXT_MAX - 1).chain(['…']).collect()
}

/// The longest resume command, in Unicode scalar values (`char`s).
pub const RESUME_CMD_MAX: usize = 256;

/// Accepts a command that runs as exactly one visible line: not blank, no
/// control character (U+2028 and U+2029 count as one), no invisible format or
/// bidi character, at most `RESUME_CMD_MAX` chars. The cli, the daemon and the
/// app (`ResumeCommand.check`) each apply it. `Err` names the cause.
pub fn check_resume_cmd(cmd: &str) -> Result<(), &'static str> {
    check_cmd(cmd, RESUME_CMD_MAX, "over 256 characters")
}

/// The character rules every command check shares, then the limit `max`,
/// refused as `over`.
fn check_cmd(cmd: &str, max: usize, over: &'static str) -> Result<(), &'static str> {
    if cmd.trim().is_empty() {
        return Err("empty");
    }
    if cmd.chars().any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')) {
        return Err("a control character");
    }
    if cmd.chars().any(is_invisible_format) {
        return Err("an invisible format character");
    }
    if cmd.chars().count() > max {
        return Err(over);
    }
    Ok(())
}

/// `check_resume_cmd`, with the refusal worded as the cli and the daemon
/// print it.
pub fn refuse_resume_cmd(cmd: &str) -> Result<(), String> {
    check_resume_cmd(cmd).map_err(|cause| format!("resume command refused: {cause}"))
}

/// The longest `term new` command, in Unicode scalar values (`char`s).
pub const TERM_NEW_CMD_MAX: usize = 4096;

/// The rules of `check_resume_cmd` with the limit `TERM_NEW_CMD_MAX`: an
/// agent's prompt in the command can be long. The cli and the daemon each
/// apply it.
pub fn check_term_new_cmd(cmd: &str) -> Result<(), &'static str> {
    check_cmd(cmd, TERM_NEW_CMD_MAX, "over 4096 characters")
}

/// `check_term_new_cmd`, with the refusal worded as the cli and the daemon
/// print it.
pub fn refuse_term_new_cmd(cmd: &str) -> Result<(), String> {
    check_term_new_cmd(cmd).map_err(|cause| format!("term new command refused: {cause}"))
}

fn is_invisible_format(c: char) -> bool {
    matches!(c, '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
}

// to_vec_named is load-bearing: plain to_vec emits structs as msgpack arrays,
// violating the "map with string keys" rule.
pub fn encode(msg: &Msg) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(msg)
}

/// What the cli and the daemon answer for a value whose frame would be over
/// `MAX_FRAME_LEN`.
pub const OVER_FRAME_LIMIT: &str = "value is over the frame limit (16 MiB)";

/// `encode`, or `None` when the payload is over `limit` bytes.
pub fn encode_within(msg: &Msg, limit: usize) -> Option<Vec<u8>> {
    encode(msg).ok().filter(|payload| payload.len() <= limit)
}

pub fn decode(bytes: &[u8]) -> Result<Msg, rmp_serde::decode::Error> {
    rmp_serde::from_slice(bytes)
}

#[cfg(test)]
mod tests;
