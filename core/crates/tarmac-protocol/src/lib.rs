//! Wire types, codec, and framing for the tarmac unix-socket protocol.
//! Authoritative contract: docs/protocol.md (v1, M0 + M1 subsets).

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_LEN: u32 = 16 * 1024 * 1024;

// Eq is dropped from Msg/Tile/BoardViewport because the v4 board geometry
// fields are f64 (no Eq); PartialEq still backs the conformance assert_eq!s.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Msg {
    Hello {
        role: String,
        v: u32,
    },
    HelloOk {
        v: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        daemon_version: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        daemon_pid: Option<u32>,
    },
    Ack,
    Err {
        msg: String,
    },
    Open {
        path: String,
        // v4 Phase 3 additive key (optional; missing => nil): the term_id that
        // ran `tarmac open` (provenance + gravity owner). The CLI reads it from
        // TARMAC_TERM_ID in its pty env; the app open arm passes None for now.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
        // M3 additive key (optional; missing => the caller term's board, else
        // active): the board the opened doc should land on. Usually derived from
        // term_id daemon-side, but allowed on the wire for an explicit target.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
    },
    DocRead {
        path: String,
    },
    Layout {
        dock: Vec<String>,
        tiles: Vec<Tile>,
        // v4 board additive key (optional; missing => nil): persisted viewport.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board: Option<BoardViewport>,
        // M3 additive key (optional; missing => board-0): which board this layout
        // belongs to. The daemon applies an absent id to the active board, so a
        // single-board sender that never sets it keeps the byte-identical wire.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
    },
    Restore {
        docs: Vec<DocEntry>,
        #[serde(default)]
        tiles: Vec<Tile>,
        // v4 board additive key (optional; missing => nil): persisted viewport.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board: Option<BoardViewport>,
        // M3 additive key (optional; missing => board-0): which board is being
        // restored. The daemon stamps the restored board's id (incl. board-0) so
        // the app binds the restore unambiguously across rapid switches; restore
        // is not one of the byte-pinned conformance vectors, so additivity holds.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
        // P5 additive key (missing => empty): the term_ids the daemon currently
        // owns a *live* pty for on this board. The app re-binds these cards to the
        // running shells (and consumes their replayed scrollback that follows the
        // restore) instead of cold-spawning fresh ones. Empty => cold-spawn — the
        // pre-P5 behaviour, and the daemon-restart case where the shells are gone.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        live_terms: Vec<String>,
    },
    SpawnTerm {
        term_id: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        cmd: Option<Vec<String>>,
        // M3 additive key (optional; missing => board-0 / active): the board the
        // new terminal card belongs to. The daemon records term_id -> board_id
        // at spawn so restore, teardown and `tarmac open` provenance scope per
        // board even when the target board is not the active one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board_id: Option<String>,
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
    // M2 honest signals (daemon -> app; additive message types). A receiver
    // that does not know them ignores them (Unknown), so they are safe.
    TermProc {
        term_id: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pid: Option<i64>,
    },
    Bell {
        term_id: String,
    },
    // M3 ("strips = boards"; additive message types). A receiver that does not
    // know them ignores them (Unknown), so they are safe on the wire.
    //
    // BoardList (daemon -> app): the full set of boards in display order plus
    // the active one. Pushed right after hello_ok and on every board change.
    BoardList {
        boards: Vec<BoardMeta>,
        active: String,
    },
    // BoardSwitch (app -> daemon): make `board_id` active; the daemon replies
    // with that board's restore.
    BoardSwitch {
        board_id: String,
    },
    // BoardCreate (app -> daemon): mint a fresh board (the daemon assigns the
    // slug id) and re-emit board_list. P5 adds rename/delete.
    BoardCreate,
    // BoardRename (app -> daemon, P5.4): set `board_id`'s display name. An empty
    // `name` clears it back to the slug fallback. The daemon re-emits board_list.
    BoardRename {
        board_id: String,
        name: String,
    },
    // BoardDelete (app -> daemon, P5.4): remove `board_id`, kill its ptys, and
    // re-emit board_list (+ the now-active board's restore when the deleted board
    // was active). Refused (no-op) when it is the last board; the daemon fixes the
    // active board if the deleted one was active.
    BoardDelete {
        board_id: String,
    },
    // TermClose (app -> daemon, issue #15): kill one terminal's pty (SIGHUP to its
    // process group, reusing TermHandle::kill) so ⌘W can close a single terminal
    // card. The pump's wait thread then runs the normal exit cleanup (terms/
    // term_boards removal, Exit + board_list). An unknown term_id is a no-op.
    TermClose {
        term_id: String,
    },
    // DocClose (app -> daemon, issue #34): forget a doc — prune Registry.docs +
    // dock, persist state.json, unwatch the parent dir iff no remaining doc in
    // the registry shares it. Idempotent: an unknown path is a silent no-op.
    DocClose {
        path: String,
    },
    // Unknown message types are ignored, not fatal (protocol rule).
    #[serde(other)]
    Unknown,
}

/// M3: one board's identity for the boards switcher (`board_list`). `name` is
/// the user-given display name (absent until named — manual naming only); the
/// switcher falls back to the slug `board_id`. Display order is the vec order.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct BoardMeta {
    pub board_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    // P5 additive key (optional; missing => unknown): the count of *live* ptys
    // the daemon owns for this board (term_boards ∩ terms). This is the honest
    // per-board liveness the app cannot derive for a never-visited board (it has
    // no cards yet); the daemon re-pushes board_list when this crosses on spawn
    // /exit. A board with zero live terms still emits Some(0); only a pre-P5
    // sender omits the key, so existing board_list vectors decode None and
    // re-encode byte-identically.
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
    // Wire default is true: an entry without the key (M0 sender) never renders
    // an unread dot.
    #[serde(default = "read_default")]
    pub read: bool,
    pub last_changed_ms: Option<u64>,
    pub last_opened_ms: Option<u64>,
    // v4 Phase 3 additive key (optional; missing => nil): the term that opened
    // the doc (provenance + gravity owner). Carried through restore/doc_opened.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_id: Option<String>,
}

fn read_default() -> bool {
    true
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Tile {
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    // v4 board additive keys (optional; missing => nil): the world-space card
    // frame and stacking order. A tile without these behaves as an M1 tile
    // (the app falls back to grid placement), so M1 frames decode identically.
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
    // v4 Phase 3 additive keys (optional; missing => nil): `loose` is the
    // gravity-detached flag (missing => attached); `shelf` true => the doc is
    // parked on the shelf rather than placed on the board (a shelf doc tile has
    // kind "doc", shelf:true, and no x/y/w/h).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub loose: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shelf: Option<bool>,
    // v4 Phase 5b additive key (optional; missing => nil): the `term_id` a
    // terminal tile belongs to, so N terminal cards persist distinct positions.
    // Absent on doc tiles and on legacy single-terminal layouts (the daemon
    // keeps exactly one `None`-keyed term tile; see `Registry::set_tiles`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub term_id: Option<String>,
}

/// The persisted board viewport for a strip: zoom factor + world-space center.
/// v4 additive (`restore.board` / `layout.board`); whole map missing => nil.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct BoardViewport {
    pub zoom: f64,
    pub cx: f64,
    pub cy: f64,
}

/// FNV-1a 64-bit over the repo name, mod 4 → palette index 0..=3.
/// Must stay byte-for-byte identical to the app's Theme.repoColor(for:):
/// M0 peek-header colors must not change when the daemon takes over hashing.
pub fn repo_color_index(repo: &str) -> u8 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in repo.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    (hash % 4) as u8
}

// ---------------------------------------------------------------------------
// 2606.0003: per-channel daemon socket + state path derivation.
//
// The daemon and CLI both depend on this crate, so the path logic — and the
// `dev` literal — live here ONCE, shared by construction. Each binary keeps
// only a thin shell that maps its own build configuration to a `Channel` and
// joins the filename it needs. The Swift app mirrors this in `ChannelPaths`
// across the language boundary (the only place the literal is duplicated).
// ---------------------------------------------------------------------------

use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

/// Build channel. `Release` == the shipped, signed bundle
/// (`cfg!(debug_assertions) == false`); `Dev` == any debug build
/// (`cfg!(debug_assertions) == true`). The channel is each binary's own
/// immutable build configuration, mapped to this enum at exactly one audited
/// line per binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Channel {
    Release,
    Dev,
}

/// PURE per-channel directory. Both path resolvers SHARE this for their
/// default branch, so the `dev` literal exists once and the socket and state
/// files always carry the SAME channel segment (spec S7). Takes NO override —
/// it only produces the directory.
/// Default = `home`/Library/Application Support/tarmac` + [`Dev` => `/dev`].
pub fn channel_dir(home: &Path, channel: Channel) -> PathBuf {
    let base = home.join("Library/Application Support/tarmac");
    match channel {
        Channel::Release => base,
        Channel::Dev => base.join("dev"),
    }
}

/// PURE socket resolver. `over` is the `TARMAC_SOCKET` value read by the shell;
/// a present **and non-empty** value wins VERBATIM (empty is treated as unset —
/// unified with Swift, spec S9). Otherwise the default is
/// `channel_dir(home, channel)/tarmacd.sock`; `Release` is byte-for-byte
/// today's flat path, so existing users are never migrated (spec S1).
pub fn resolve_socket_path(over: Option<OsString>, home: &OsStr, channel: Channel) -> PathBuf {
    if let Some(p) = over.filter(|v| !v.is_empty()) {
        return PathBuf::from(p);
    }
    channel_dir(Path::new(home), channel).join("tarmacd.sock")
}

/// PURE state resolver (used by `tarmacd` only — the CLI and app hold no state).
/// Same shape as `resolve_socket_path` with `state.json`, so dev state lands
/// beside the dev socket under one per-channel dir (spec S6/S7).
pub fn resolve_state_path(over: Option<OsString>, home: &OsStr, channel: Channel) -> PathBuf {
    if let Some(p) = over.filter(|v| !v.is_empty()) {
        return PathBuf::from(p);
    }
    channel_dir(Path::new(home), channel).join("state.json")
}

/// PURE length guard for a Unix-domain socket path. macOS caps
/// sockaddr_un.sun_path at 104 bytes; bind/connect fail opaquely past it.
/// Ok(())  iff path.as_os_str().len() < 104  (103 = OK).
/// Err(msg) iff len >= 104 (104 = rejected); msg names the byte length,
/// the 104-byte cap, AND the remedy (set TARMAC_SOCKET shorter, e.g. /tmp).
/// SEPARATE from resolve_socket_path: resolution vs validation (SRP).
pub fn check_socket_path_len(path: &std::path::Path) -> Result<(), String> {
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

/// Human channel label for diagnostics: `Release` => `"release"`,
/// `Dev` => `"dev"`. Mirrors Swift `ChannelPaths.channelLabel`; the impure
/// "no daemon" / startup messages format it in (spec S10).
pub fn channel_label(channel: Channel) -> &'static str {
    match channel {
        Channel::Release => "release",
        Channel::Dev => "dev",
    }
}

// to_vec_named is load-bearing: plain to_vec emits structs as msgpack arrays,
// violating the "map with string keys" rule.
pub fn encode(msg: &Msg) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(msg)
}

pub fn decode(bytes: &[u8]) -> Result<Msg, rmp_serde::decode::Error> {
    rmp_serde::from_slice(bytes)
}

pub mod frame {
    use super::MAX_FRAME_LEN;
    use std::io::{self, Read, Write};

    fn too_large(n: u64) -> io::Error {
        io::Error::new(io::ErrorKind::InvalidData, format!("frame too large: {n}"))
    }

    pub fn read_sync(r: &mut impl Read) -> io::Result<Vec<u8>> {
        let mut len = [0u8; 4];
        r.read_exact(&mut len)?;
        let n = u32::from_be_bytes(len);
        if n > MAX_FRAME_LEN {
            return Err(too_large(n as u64));
        }
        let mut buf = vec![0u8; n as usize];
        r.read_exact(&mut buf)?;
        Ok(buf)
    }

    pub fn write_sync(w: &mut impl Write, payload: &[u8]) -> io::Result<()> {
        if payload.len() as u64 > MAX_FRAME_LEN as u64 {
            return Err(too_large(payload.len() as u64));
        }
        w.write_all(&(payload.len() as u32).to_be_bytes())?;
        w.write_all(payload)
    }

    #[cfg(feature = "async")]
    pub async fn read_async(r: &mut (impl tokio::io::AsyncRead + Unpin)) -> io::Result<Vec<u8>> {
        use tokio::io::AsyncReadExt;
        let mut len = [0u8; 4];
        r.read_exact(&mut len).await?;
        let n = u32::from_be_bytes(len);
        if n > MAX_FRAME_LEN {
            return Err(too_large(n as u64));
        }
        let mut buf = vec![0u8; n as usize];
        r.read_exact(&mut buf).await?;
        Ok(buf)
    }

    #[cfg(feature = "async")]
    pub async fn write_async(
        w: &mut (impl tokio::io::AsyncWrite + Unpin),
        payload: &[u8],
    ) -> io::Result<()> {
        use tokio::io::AsyncWriteExt;
        if payload.len() as u64 > MAX_FRAME_LEN as u64 {
            return Err(too_large(payload.len() as u64));
        }
        w.write_all(&(payload.len() as u32).to_be_bytes()).await?;
        w.write_all(payload).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        let digits: Vec<u8> = s
            .chars()
            .filter(|c| c.is_ascii_hexdigit())
            .map(|c| c.to_digit(16).unwrap() as u8)
            .collect();
        assert!(digits.len() % 2 == 0);
        digits.chunks(2).map(|p| (p[0] << 4) | p[1]).collect()
    }

    fn m0_entry(path: &str, via: &str, last_changed_ms: Option<u64>) -> DocEntry {
        DocEntry {
            path: path.into(),
            via: via.into(),
            repo: None,
            repo_root: None,
            repo_color: None,
            read: true,
            last_changed_ms,
            last_opened_ms: None,
            term_id: None,
        }
    }

    // Geometry-less tiles (M1 shape): v4 x/y/w/h/z (and Phase 3 loose/shelf)
    // default to None, so these encode/decode exactly as M1 frames did.
    fn term_tile() -> Tile {
        Tile {
            kind: "term".into(),
            path: None,
            x: None,
            y: None,
            w: None,
            h: None,
            z: None,
            loose: None,
            shelf: None,
            term_id: None,
        }
    }

    fn doc_tile(path: &str) -> Tile {
        Tile { kind: "doc".into(), path: Some(path.into()), ..term_tile() }
    }

    fn roundtrip(m: &Msg) -> Msg {
        decode(&encode(m).unwrap()).unwrap()
    }

    fn assert_vector(hex: &str, expected: Msg) {
        let decoded = decode(&unhex(hex)).unwrap();
        assert_eq!(decoded, expected);
        assert_eq!(roundtrip(&expected), expected);
    }

    #[test]
    fn conformance_vector_1_ack() {
        assert_vector("81 a1 74 a3 61 63 6b", Msg::Ack);
    }

    #[test]
    fn conformance_vector_2_hello() {
        assert_vector(
            "83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01",
            Msg::Hello { role: "app".into(), v: 1 },
        );
    }

    #[test]
    fn conformance_vector_3_input() {
        assert_vector(
            "83 a1 74 a5 69 6e 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31 \
             a5 62 79 74 65 73 c4 03 6c 73 0a",
            Msg::Input { term_id: "t1".into(), bytes: b"ls\n".to_vec() },
        );
    }

    #[test]
    fn conformance_vector_4_resize() {
        assert_vector(
            "84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31 \
             a4 63 6f 6c 73 78 a4 72 6f 77 73 28",
            Msg::Resize { term_id: "t1".into(), cols: 120, rows: 40 },
        );
    }

    #[test]
    fn conformance_vector_5_doc_read() {
        assert_vector(
            "82 a1 74 a8 64 6f 63 5f 72 65 61 64 a4 70 61 74 68 a5 2f 61 2e 6d 64",
            Msg::DocRead { path: "/a.md".into() },
        );
    }

    #[test]
    fn conformance_vector_6_layout() {
        assert_vector(
            "83 a1 74 a6 6c 61 79 6f 75 74 \
             a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
             a5 74 69 6c 65 73 92 \
             81 a4 6b 69 6e 64 a4 74 65 72 6d \
             82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64",
            Msg::Layout {
                dock: vec!["/a.md".into()],
                tiles: vec![term_tile(), doc_tile("/a.md")],
                board: None,
                board_id: None,
            },
        );
    }

    #[test]
    fn conformance_vector_7_doc_opened_extended() {
        assert_vector(
            "87 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 \
             a4 70 61 74 68 a5 2f 61 2e 6d 64 \
             a3 76 69 61 a3 63 6c 69 \
             a4 72 65 70 6f a3 61 70 69 \
             aa 72 65 70 6f 5f 63 6f 6c 6f 72 03 \
             a4 72 65 61 64 c2 \
             ae 6c 61 73 74 5f 6f 70 65 6e 65 64 5f 6d 73 cf 00 00 01 90 00 c7 9c 00",
            Msg::DocOpened(DocEntry {
                path: "/a.md".into(),
                via: "cli".into(),
                repo: Some("api".into()),
                repo_root: None,
                repo_color: Some(3),
                read: false,
                last_changed_ms: None,
                last_opened_ms: Some(1_718_000_000_000),
                term_id: None,
            }),
        );
    }

    #[test]
    fn conformance_vector_8_v4_board_keys() {
        // docs/protocol.md vector 8: a layout whose doc tile carries x,y,w,h,z
        // and whose top level carries a board {zoom,cx,cy}. float64 (cb) values.
        assert_vector(
            "84 a1 74 a6 6c 61 79 6f 75 74 \
             a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
             a5 74 69 6c 65 73 91 \
             87 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64 \
             a1 78 cb 40 5e 00 00 00 00 00 00 \
             a1 79 cb 40 54 00 00 00 00 00 00 \
             a1 77 cb 40 7d 60 00 00 00 00 00 \
             a1 68 cb 40 74 a0 00 00 00 00 00 \
             a1 7a 02 \
             a5 62 6f 61 72 64 83 \
             a4 7a 6f 6f 6d cb 3f ea 3d 70 a3 d7 0a 3d \
             a2 63 78 cb 40 84 00 00 00 00 00 00 \
             a2 63 79 cb 40 76 80 00 00 00 00 00",
            Msg::Layout {
                dock: vec!["/a.md".into()],
                tiles: vec![Tile {
                    kind: "doc".into(),
                    path: Some("/a.md".into()),
                    x: Some(120.0),
                    y: Some(80.0),
                    w: Some(470.0),
                    h: Some(330.0),
                    z: Some(2),
                    loose: None,
                    shelf: None,
                    term_id: None,
                }],
                board: Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }),
                board_id: None,
            },
        );
    }

    #[test]
    fn conformance_vector_9_term_close() {
        // issue #15: a new additive app -> daemon type. Decodes by tag and
        // round-trips; existing vectors are unaffected (unknown-type rule).
        assert_vector(
            "82 a1 74 aa 74 65 72 6d 5f 63 6c 6f 73 65 \
             a7 74 65 72 6d 5f 69 64 a2 74 31",
            Msg::TermClose { term_id: "t1".into() },
        );
    }

    #[test]
    fn conformance_vector_10_doc_close() {
        // issue #34: a new additive app -> daemon type. Decodes by tag and
        // round-trips; existing vectors V1-V9 are unaffected (unknown-type rule).
        assert_vector(
            "82 a1 74 a9 64 6f 63 5f 63 6c 6f 73 65 \
             a4 70 61 74 68 a5 2f 61 2e 6d 64",
            Msg::DocClose { path: "/a.md".into() },
        );
    }

    #[test]
    fn m0_shaped_doc_opened_decodes_with_defaults() {
        // {t:"doc_opened", path:"/a.md", via:"cli"} — exactly what an M0 daemon sends
        let bytes = unhex(
            "83 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 \
             a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69",
        );
        assert_eq!(decode(&bytes).unwrap(), Msg::DocOpened(m0_entry("/a.md", "cli", None)));
    }

    #[test]
    fn m0_shaped_restore_decodes_with_defaults() {
        // {t:"restore", docs:[{path:"/a.md", via:"cli", last_changed_ms:nil}]} — no tiles key
        let bytes = unhex(
            "82 a1 74 a7 72 65 73 74 6f 72 65 a4 64 6f 63 73 91 \
             83 a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69 \
             af 6c 61 73 74 5f 63 68 61 6e 67 65 64 5f 6d 73 c0",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::Restore { docs: vec![m0_entry("/a.md", "cli", None)], tiles: vec![], board: None, board_id: None, live_terms: vec![] }
        );
    }

    #[test]
    fn m1_shaped_layout_decodes_with_nil_board_and_tile_geometry() {
        // Conformance vector 6 verbatim — an M1 layout with no `board` key and
        // geometry-less tiles. Decoding it under v4 must still produce all-None
        // geometry + board None (additive guarantee).
        let bytes = unhex(
            "83 a1 74 a6 6c 61 79 6f 75 74 \
             a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
             a5 74 69 6c 65 73 92 \
             81 a4 6b 69 6e 64 a4 74 65 72 6d \
             82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::Layout {
                dock: vec!["/a.md".into()],
                tiles: vec![term_tile(), doc_tile("/a.md")],
                board: None,
                board_id: None,
            }
        );
    }

    #[test]
    fn v4_board_keys_decode_from_wire() {
        // {t:"layout", dock:[], tiles:[{kind:"doc", path:"/a.md", x:1.0, y:2.0,
        //  w:3.0, h:4.0, z:5}], board:{zoom:0.5, cx:10.0, cy:20.0}}
        let msg = Msg::Layout {
            dock: vec![],
            tiles: vec![Tile {
                kind: "doc".into(),
                path: Some("/a.md".into()),
                x: Some(1.0),
                y: Some(2.0),
                w: Some(3.0),
                h: Some(4.0),
                z: Some(5),
                loose: None,
                shelf: None,
                term_id: None,
            }],
            board: Some(BoardViewport { zoom: 0.5, cx: 10.0, cy: 20.0 }),
            board_id: None,
        };
        assert_eq!(roundtrip(&msg), msg);
    }

    // v4 Phase 3 (additive): a tile carrying loose + shelf round-trips; an
    // entry carrying term_id round-trips; an open carrying term_id round-trips.
    #[test]
    fn phase3_loose_shelf_and_term_id_roundtrip() {
        // A shelf-parked, gravity-detached doc tile (no geometry).
        let shelf_tile = Tile {
            kind: "doc".into(),
            path: Some("/a.md".into()),
            x: None,
            y: None,
            w: None,
            h: None,
            z: None,
            loose: Some(true),
            shelf: Some(true),
            term_id: None,
        };
        assert_eq!(
            roundtrip(&Msg::Layout {
                dock: vec!["/a.md".into()],
                tiles: vec![shelf_tile.clone()],
                board: None,
                board_id: None,
            }),
            Msg::Layout { dock: vec!["/a.md".into()], tiles: vec![shelf_tile], board: None, board_id: None }
        );

        // A doc entry carrying its opener term_id.
        let entry = DocEntry {
            path: "/a.md".into(),
            via: "cli".into(),
            repo: None,
            repo_root: None,
            repo_color: None,
            read: false,
            last_changed_ms: None,
            last_opened_ms: Some(1),
            term_id: Some("term-42".into()),
        };
        assert_eq!(roundtrip(&Msg::DocOpened(entry.clone())), Msg::DocOpened(entry));

        // An open carrying the calling term_id.
        let open = Msg::Open { path: "/a.md".into(), term_id: Some("term-42".into()), board_id: None };
        assert_eq!(roundtrip(&open), open);
    }

    // v4 Phase 5b (additive): a terminal tile carrying its `term_id` round-trips,
    // and a multi-terminal layout preserves two distinct term tile ids + order.
    #[test]
    fn phase5b_term_tile_term_id_roundtrip() {
        let t1 = Tile { kind: "term".into(), term_id: Some("t1".into()), ..term_tile() };
        let t2 = Tile {
            kind: "term".into(),
            term_id: Some("t2".into()),
            x: Some(600.0),
            y: Some(80.0),
            ..term_tile()
        };
        let layout = Msg::Layout {
            dock: vec!["/a.md".into()],
            tiles: vec![t1.clone(), t2.clone(), doc_tile("/a.md")],
            board: None,
            board_id: None,
        };
        let rt = roundtrip(&layout);
        assert_eq!(rt, layout);
        // Both term ids survive, distinct, in order.
        if let Msg::Layout { tiles, .. } = rt {
            assert_eq!(tiles[0].term_id.as_deref(), Some("t1"));
            assert_eq!(tiles[1].term_id.as_deref(), Some("t2"));
            assert_eq!(tiles[2].term_id, None); // a doc tile carries no term_id
        } else {
            panic!("expected layout");
        }
    }

    // A keyless term tile (legacy single-terminal layout) decodes term_id == None
    // and is byte-identical to the pre-5b encoding (additive guarantee).
    #[test]
    fn phase5b_keyless_term_tile_decodes_to_none() {
        let rt = roundtrip(&Msg::Layout {
            dock: vec![],
            tiles: vec![term_tile()],
            board: None,
            board_id: None,
        });
        if let Msg::Layout { tiles, .. } = rt {
            assert_eq!(tiles[0].term_id, None);
        } else {
            panic!("expected layout");
        }
        // A bare term tile (all-None) still serializes to the same 11 bytes it
        // did pre-5b — `skip_serializing_if` omits term_id, so {kind:"term"}.
        let bytes = unhex("81 a4 6b 69 6e 64 a4 74 65 72 6d");
        assert_eq!(rmp_serde::to_vec_named(&term_tile()).unwrap(), bytes);
    }

    // M3 (additive): a layout / restore carrying a `board_id` round-trips, and a
    // distinct id survives — the wire half of "strips = boards".
    #[test]
    fn m3_board_id_roundtrip() {
        let layout = Msg::Layout {
            dock: vec!["/a.md".into()],
            tiles: vec![term_tile()],
            board: None,
            board_id: Some("board-1".into()),
        };
        let rt = roundtrip(&layout);
        assert_eq!(rt, layout);
        if let Msg::Layout { board_id, .. } = rt {
            assert_eq!(board_id.as_deref(), Some("board-1"));
        } else {
            panic!("expected layout");
        }

        let restore = Msg::Restore {
            docs: vec![m0_entry("/a.md", "cli", None)],
            tiles: vec![term_tile()],
            board: Some(BoardViewport { zoom: 1.0, cx: 0.0, cy: 0.0 }),
            board_id: Some("board-2".into()),
            live_terms: vec![],
        };
        assert_eq!(roundtrip(&restore), restore);
    }

    // A board_id-less layout (conformance vector 6 verbatim) decodes board_id ==
    // None, and a None-keyed layout re-encodes without a `board_id` key — so a
    // single-board sender's wire is byte-identical to the pre-M3 frame.
    #[test]
    fn m3_keyless_layout_decodes_board_id_none() {
        let bytes = unhex(
            "83 a1 74 a6 6c 61 79 6f 75 74 \
             a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
             a5 74 69 6c 65 73 92 \
             81 a4 6b 69 6e 64 a4 74 65 72 6d \
             82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64",
        );
        let Msg::Layout { board_id, .. } = decode(&bytes).unwrap() else { panic!("not layout") };
        assert_eq!(board_id, None);

        // The re-encoded frame is byte-identical to the input (no board_id key).
        let none_keyed = Msg::Layout {
            dock: vec!["/a.md".into()],
            tiles: vec![term_tile(), doc_tile("/a.md")],
            board: None,
            board_id: None,
        };
        assert_eq!(encode(&none_keyed).unwrap(), bytes);
    }

    // M3 P2: a board_list decodes from the wire (a board with no name omits the
    // key and decodes None); board_switch / board_create round-trip.
    #[test]
    fn m3_board_list_decodes_from_wire() {
        // {t:"board_list", boards:[{board_id:"board-0"},{board_id:"board-1",
        //  name:"infra"}], active:"board-1"}
        let bytes = unhex(
            "83 a1 74 aa 62 6f 61 72 64 5f 6c 69 73 74 \
             a6 62 6f 61 72 64 73 92 \
             81 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 30 \
             82 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 31 \
             a4 6e 61 6d 65 a5 69 6e 66 72 61 \
             a6 61 63 74 69 76 65 a7 62 6f 61 72 64 2d 31",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::BoardList {
                boards: vec![
                    BoardMeta { board_id: "board-0".into(), name: None, running: None },
                    BoardMeta { board_id: "board-1".into(), name: Some("infra".into()), running: None },
                ],
                active: "board-1".into(),
            }
        );

        let sw = Msg::BoardSwitch { board_id: "board-2".into() };
        assert_eq!(roundtrip(&sw), sw);
        assert_eq!(roundtrip(&Msg::BoardCreate), Msg::BoardCreate);
    }

    // P5 (additive): BoardMeta.running carries the daemon's live-pty count per
    // board. A board_list with running set round-trips; running:None (a pre-P5
    // sender) omits the key on the wire, distinct from an explicit running:0.
    #[test]
    fn p5_board_meta_running_roundtrips() {
        let list = Msg::BoardList {
            boards: vec![
                BoardMeta { board_id: "board-0".into(), name: None, running: Some(2) },
                BoardMeta { board_id: "board-1".into(), name: Some("infra".into()), running: Some(0) },
            ],
            active: "board-0".into(),
        };
        assert_eq!(roundtrip(&list), list);

        // running:None omits the key (byte-identical to the pre-P5 wire); an
        // explicit running:0 is a real key — the two encodings differ.
        let none_keyed = Msg::BoardList {
            boards: vec![BoardMeta { board_id: "board-0".into(), name: None, running: None }],
            active: "board-0".into(),
        };
        let zero_keyed = Msg::BoardList {
            boards: vec![BoardMeta { board_id: "board-0".into(), name: None, running: Some(0) }],
            active: "board-0".into(),
        };
        assert_ne!(encode(&none_keyed).unwrap(), encode(&zero_keyed).unwrap());
    }

    // P5 (additive; the plan's "V11" session-bearing restore): a restore carrying
    // `live_terms` round-trips, and a live_terms-less restore (the pre-P5 wire)
    // omits the key entirely — so every earlier restore decodes an empty list and
    // re-encodes byte-identically.
    #[test]
    fn p5_restore_live_terms_roundtrips() {
        let restore = Msg::Restore {
            docs: vec![m0_entry("/a.md", "cli", None)],
            tiles: vec![term_tile()],
            board: None,
            board_id: Some("board-1".into()),
            live_terms: vec!["t1".into(), "t2".into()],
        };
        assert_eq!(roundtrip(&restore), restore);

        // An empty live_terms omits the key (byte-identical to the pre-P5 wire);
        // a non-empty list is a real key, so the encodings differ.
        let empty = Msg::Restore {
            docs: vec![], tiles: vec![], board: None, board_id: None, live_terms: vec![],
        };
        let one = Msg::Restore {
            docs: vec![], tiles: vec![], board: None, board_id: None, live_terms: vec!["t1".into()],
        };
        let empty_bytes = encode(&empty).unwrap();
        let Msg::Restore { live_terms, .. } = decode(&empty_bytes).unwrap() else { panic!("not restore") };
        assert!(live_terms.is_empty(), "absent live_terms decodes empty");
        assert_ne!(encode(&one).unwrap(), empty_bytes);
    }

    // P5.4 (additive app -> daemon types): board_rename / board_delete round-trip
    // (named + empty-name rename), and a hand-built wire frame decodes by tag.
    #[test]
    fn p5_board_rename_and_delete_roundtrip() {
        let rename = Msg::BoardRename { board_id: "board-1".into(), name: "infra".into() };
        assert_eq!(roundtrip(&rename), rename);
        // An empty name (clear-to-slug) round-trips too.
        let clear = Msg::BoardRename { board_id: "board-1".into(), name: String::new() };
        assert_eq!(roundtrip(&clear), clear);
        let delete = Msg::BoardDelete { board_id: "board-1".into() };
        assert_eq!(roundtrip(&delete), delete);

        // {t:"board_rename", board_id:"board-1", name:"infra"} from the wire.
        let bytes = unhex(
            "83 a1 74 ac 62 6f 61 72 64 5f 72 65 6e 61 6d 65 \
             a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 31 \
             a4 6e 61 6d 65 a5 69 6e 66 72 61",
        );
        assert_eq!(decode(&bytes).unwrap(), rename);
        // {t:"board_delete", board_id:"board-1"} from the wire.
        let del_bytes = unhex(
            "82 a1 74 ac 62 6f 61 72 64 5f 64 65 6c 65 74 65 \
             a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 31",
        );
        assert_eq!(decode(&del_bytes).unwrap(), delete);
    }

    // M3 P2: a keyless spawn_term / open (pre-M3 sender) decodes board_id None.
    #[test]
    fn m3_keyless_spawn_and_open_decode_board_id_none() {
        // {t:"spawn_term", term_id:"t1", cols:80, rows:24} — no board_id key.
        let spawn = unhex(
            "84 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d \
             a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18",
        );
        assert_eq!(
            decode(&spawn).unwrap(),
            Msg::SpawnTerm { term_id: "t1".into(), cols: 80, rows: 24, cwd: None, cmd: None, board_id: None }
        );

        // {t:"open", path:"/a.md"} — no term_id / board_id keys.
        let open = unhex("82 a1 74 a4 6f 70 65 6e a4 70 61 74 68 a5 2f 61 2e 6d 64");
        assert_eq!(
            decode(&open).unwrap(),
            Msg::Open { path: "/a.md".into(), term_id: None, board_id: None }
        );
    }

    // Key-less M1 shapes still decode to None for the Phase 3 fields (additive
    // guarantee): a tile with no loose/shelf, an entry with no term_id, an open
    // with no term_id.
    #[test]
    fn phase3_keyless_shapes_decode_to_none() {
        // {t:"open", path:"/a.md"} — an M0/M1 open with no term_id key.
        let open_bytes = unhex("82 a1 74 a4 6f 70 65 6e a4 70 61 74 68 a5 2f 61 2e 6d 64");
        assert_eq!(
            decode(&open_bytes).unwrap(),
            Msg::Open { path: "/a.md".into(), term_id: None, board_id: None }
        );

        // {t:"doc_opened", path:"/a.md", via:"cli"} — no term_id key.
        let opened_bytes = unhex(
            "83 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64 \
             a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69",
        );
        let Msg::DocOpened(entry) = decode(&opened_bytes).unwrap() else { panic!("not doc_opened") };
        assert_eq!(entry.term_id, None);

        // Conformance vector 6 (M1 layout) decodes with loose/shelf == None.
        let layout_bytes = unhex(
            "83 a1 74 a6 6c 61 79 6f 75 74 \
             a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
             a5 74 69 6c 65 73 92 \
             81 a4 6b 69 6e 64 a4 74 65 72 6d \
             82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64",
        );
        let Msg::Layout { tiles, .. } = decode(&layout_bytes).unwrap() else { panic!("not layout") };
        assert_eq!(tiles[0].loose, None);
        assert_eq!(tiles[0].shelf, None);
        assert_eq!(tiles[1].loose, None);
        assert_eq!(tiles[1].shelf, None);
    }

    #[test]
    fn repo_color_index_matches_theme_hash() {
        // Reference values from docs/archive/m1/crib-state.md §1.2 (app's Theme.swift FNV-1a).
        assert_eq!(repo_color_index("payments-api"), 3);
        assert_eq!(repo_color_index("search-svc"), 2);
        assert_eq!(repo_color_index("infra"), 1);
        assert_eq!(repo_color_index("api"), 3);
    }

    #[test]
    fn unknown_message_type_decodes_to_unknown() {
        // {t:"frobnicate", x:1}
        let bytes = unhex("82 a1 74 aa 66 72 6f 62 6e 69 63 61 74 65 a1 78 01");
        assert_eq!(decode(&bytes).unwrap(), Msg::Unknown);
    }

    #[test]
    fn unknown_keys_are_ignored() {
        // {t:"ack", x:1}
        let bytes = unhex("82 a1 74 a3 61 63 6b a1 78 01");
        assert_eq!(decode(&bytes).unwrap(), Msg::Ack);
    }

    #[test]
    fn key_order_is_irrelevant_even_with_tag_last_and_bin_payload() {
        // {bytes:"ls\n", term_id:"t1", t:"input"}
        let bytes = unhex(
            "83 a5 62 79 74 65 73 c4 03 6c 73 0a \
             a7 74 65 72 6d 5f 69 64 a2 74 31 a1 74 a5 69 6e 70 75 74",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::Input { term_id: "t1".into(), bytes: b"ls\n".to_vec() }
        );
    }

    #[test]
    fn missing_optional_keys_decode_as_nil() {
        // {t:"spawn_term", term_id:"t1", cols:80, rows:24} — no cwd/cmd keys
        let bytes = unhex(
            "84 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d \
             a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::SpawnTerm { term_id: "t1".into(), cols: 80, rows: 24, cwd: None, cmd: None, board_id: None }
        );
    }

    #[test]
    fn explicit_nil_optionals_decode_as_none() {
        // {t:"spawn_term", term_id:"t1", cols:80, rows:24, cwd:nil, cmd:nil}
        let bytes = unhex(
            "86 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d \
             a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18 \
             a3 63 77 64 c0 a3 63 6d 64 c0",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::SpawnTerm { term_id: "t1".into(), cols: 80, rows: 24, cwd: None, cmd: None, board_id: None }
        );
    }

    #[test]
    fn wide_integer_encodings_are_accepted() {
        // resize with cols as uint32 (0xce)
        let bytes = unhex(
            "84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31 \
             a4 63 6f 6c 73 ce 00 00 00 78 a4 72 6f 77 73 28",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::Resize { term_id: "t1".into(), cols: 120, rows: 40 }
        );
    }

    #[test]
    fn byte_fields_encode_with_bin_family() {
        let encoded = encode(&Msg::Input { term_id: "t1".into(), bytes: b"ls\n".to_vec() }).unwrap();
        let needle = [0xc4u8, 0x03, 0x6c, 0x73, 0x0a]; // bin8, len 3, "ls\n"
        assert!(
            encoded.windows(needle.len()).any(|w| w == needle),
            "bytes not bin-encoded: {encoded:02x?}"
        );
    }

    #[test]
    fn all_message_types_roundtrip() {
        let msgs = vec![
            Msg::Hello { role: "cli".into(), v: 1 },
            Msg::HelloOk { v: 1, daemon_version: None, daemon_pid: None },
            Msg::Ack,
            Msg::Err { msg: "boom".into() },
            Msg::Open { path: "/tmp/a.md".into(), term_id: None, board_id: None },
            Msg::Open { path: "/tmp/a.md".into(), term_id: Some("t1".into()), board_id: None },
            Msg::DocRead { path: "/tmp/a.md".into() },
            Msg::Layout {
                dock: vec!["/a.md".into(), "/b.md".into()],
                tiles: vec![term_tile(), doc_tile("/b.md")],
                board: None,
                board_id: None,
            },
            Msg::Layout { dock: vec![], tiles: vec![], board: None, board_id: None },
            // v4 layout carrying world-frame tiles + a board viewport.
            Msg::Layout {
                dock: vec!["/b.md".into()],
                tiles: vec![
                    Tile {
                        kind: "term".into(),
                        path: None,
                        x: Some(92.0),
                        y: Some(108.0),
                        w: Some(470.0),
                        h: Some(330.0),
                        z: Some(0),
                        loose: None,
                        shelf: None,
                        term_id: None,
                    },
                    Tile {
                        kind: "doc".into(),
                        path: Some("/b.md".into()),
                        x: Some(648.0),
                        y: Some(140.0),
                        w: Some(392.0),
                        h: Some(310.0),
                        z: Some(1),
                        loose: Some(true),
                        shelf: None,
                        term_id: None,
                    },
                    // A shelf doc tile: kind "doc", shelf:true, no geometry.
                    Tile {
                        kind: "doc".into(),
                        path: Some("/c.md".into()),
                        x: None,
                        y: None,
                        w: None,
                        h: None,
                        z: None,
                        loose: Some(true),
                        shelf: Some(true),
                        term_id: None,
                    },
                ],
                board: Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }),
                board_id: None,
            },
            Msg::Restore {
                docs: vec![
                    m0_entry("/a.md", "cli", None),
                    DocEntry {
                        path: "/b.md".into(),
                        via: "user".into(),
                        repo: Some("payments-api".into()),
                        repo_root: Some("/Users/x/payments-api".into()),
                        repo_color: Some(repo_color_index("payments-api")),
                        read: false,
                        last_changed_ms: Some(1_765_432_100_123),
                        last_opened_ms: Some(1_765_432_100_456),
                        term_id: Some("t1".into()),
                    },
                ],
                tiles: vec![term_tile()],
                board: Some(BoardViewport { zoom: 1.0, cx: 0.0, cy: 0.0 }),
                board_id: None,
                // P5: exercise live_terms in the catch-all roundtrip.
                live_terms: vec!["t1".into()],
            },
            Msg::SpawnTerm {
                term_id: "t1".into(),
                cols: 120,
                rows: 40,
                cwd: Some("/tmp".into()),
                cmd: Some(vec!["/bin/echo".into(), "hi".into()]),
                board_id: None,
            },
            Msg::SpawnTerm { term_id: "t2".into(), cols: 80, rows: 24, cwd: None, cmd: None, board_id: None },
            Msg::Input { term_id: "t1".into(), bytes: vec![0u8; 64 * 1024] },
            Msg::Output { term_id: "t1".into(), bytes: b"hello\r\n".to_vec() },
            Msg::Resize { term_id: "t1".into(), cols: 80, rows: 24 },
            Msg::Exit { term_id: "t1".into(), code: Some(0) },
            Msg::Exit { term_id: "t1".into(), code: None },
            Msg::DocOpened(DocEntry {
                path: "/a.md".into(),
                via: "user".into(),
                repo: Some("infra".into()),
                repo_root: Some("/Users/x/infra".into()),
                repo_color: Some(repo_color_index("infra")),
                read: true,
                last_changed_ms: None,
                last_opened_ms: Some(1_765_432_100_123),
                term_id: None,
            }),
            Msg::FileEvent { path: "/a.md".into(), mtime_ms: 1_765_432_100_123 },
            // M2 honest signals (additive daemon -> app types).
            Msg::TermProc { term_id: "t1".into(), name: "zsh".into(), pid: Some(4242) },
            Msg::TermProc { term_id: "t1".into(), name: "vim".into(), pid: None },
            Msg::Bell { term_id: "t1".into() },
            // M3 board CRUD/list types.
            Msg::BoardList {
                boards: vec![
                    BoardMeta { board_id: "board-0".into(), name: None, running: None },
                    BoardMeta { board_id: "board-1".into(), name: Some("infra".into()), running: None },
                ],
                active: "board-1".into(),
            },
            Msg::BoardSwitch { board_id: "board-1".into() },
            Msg::BoardCreate,
            // P5.4 board rename (named + cleared) / delete.
            Msg::BoardRename { board_id: "board-1".into(), name: "infra".into() },
            Msg::BoardRename { board_id: "board-1".into(), name: String::new() },
            Msg::BoardDelete { board_id: "board-1".into() },
            // issue #15: close one terminal.
            Msg::TermClose { term_id: "t1".into() },
            // M3 board_id on spawn/open.
            Msg::SpawnTerm {
                term_id: "t9".into(),
                cols: 80,
                rows: 24,
                cwd: None,
                cmd: None,
                board_id: Some("board-1".into()),
            },
            Msg::Open { path: "/a.md".into(), term_id: Some("t9".into()), board_id: Some("board-1".into()) },
            // issue #34: close a doc card (app -> daemon).
            Msg::DocClose { path: "/tmp/a.md".into() },
        ];
        for m in msgs {
            assert_eq!(roundtrip(&m), m, "roundtrip failed for {m:?}");
        }
    }

    // M2 honest signals (additive): term_proc round-trips with and without
    // pid, and a pid-less wire shape decodes to None; bell round-trips.
    #[test]
    fn m2_term_proc_and_bell_roundtrip() {
        let with_pid = Msg::TermProc { term_id: "t1".into(), name: "claude".into(), pid: Some(99) };
        assert_eq!(roundtrip(&with_pid), with_pid);
        let no_pid = Msg::TermProc { term_id: "t1".into(), name: "claude".into(), pid: None };
        assert_eq!(roundtrip(&no_pid), no_pid);

        // {t:"term_proc", term_id:"t1", name:"vim"} — a pid-less wire shape.
        let bytes = unhex(
            "83 a1 74 a9 74 65 72 6d 5f 70 72 6f 63 \
             a7 74 65 72 6d 5f 69 64 a2 74 31 \
             a4 6e 61 6d 65 a3 76 69 6d",
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Msg::TermProc { term_id: "t1".into(), name: "vim".into(), pid: None }
        );

        let bell = Msg::Bell { term_id: "t1".into() };
        assert_eq!(roundtrip(&bell), bell);
        // {t:"bell", term_id:"t1"} from the wire.
        let bell_bytes = unhex(
            "82 a1 74 a4 62 65 6c 6c a7 74 65 72 6d 5f 69 64 a2 74 31",
        );
        assert_eq!(decode(&bell_bytes).unwrap(), Msg::Bell { term_id: "t1".into() });
    }

    #[test]
    fn large_byte_payload_uses_bin32_and_roundtrips() {
        let bytes = vec![0xabu8; 64 * 1024];
        let m = Msg::Output { term_id: "t1".into(), bytes: bytes.clone() };
        let encoded = encode(&m).unwrap();
        // bin32 marker followed by big-endian length 65536
        let needle = [0xc6u8, 0x00, 0x01, 0x00, 0x00];
        assert!(encoded.windows(needle.len()).any(|w| w == needle));
        assert_eq!(roundtrip(&m), m);
    }

    #[test]
    fn frame_roundtrip_and_oversize_rejection() {
        let payload = encode(&Msg::Ack).unwrap();
        let mut buf = Vec::new();
        frame::write_sync(&mut buf, &payload).unwrap();
        assert_eq!(&buf[..4], &(payload.len() as u32).to_be_bytes());
        let mut cursor = std::io::Cursor::new(buf);
        assert_eq!(frame::read_sync(&mut cursor).unwrap(), payload);

        let mut oversize = Vec::new();
        oversize.extend_from_slice(&(MAX_FRAME_LEN + 1).to_be_bytes());
        let mut cursor = std::io::Cursor::new(oversize);
        let err = frame::read_sync(&mut cursor).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    // -- 2606.0003: per-channel socket/state path derivation ----------------
    //
    // The resolvers both binaries call live here, so they are unit-tested ONCE.
    // Behavioral (assert returned path strings), deterministic (pure fns, no
    // env), table-driven, S-numbers in comments.

    fn os(s: &str) -> OsString {
        OsString::from(s)
    }

    // S1/S2/S3/S4/S9 for the socket resolver.
    #[test]
    fn resolve_socket_path_cases() {
        let cases: &[(Option<&str>, &str, Channel, &str)] = &[
            // S1: release == legacy flat path, byte-for-byte (backward compat).
            (None, "/Users/eplin", Channel::Release,
             "/Users/eplin/Library/Application Support/tarmac/tarmacd.sock"),
            // S2: dev inserts exactly the `dev/` segment.
            (None, "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/tarmacd.sock"),
            // S3: an explicit override wins verbatim in the release channel.
            (Some("/tmp/x.sock"), "/Users/eplin", Channel::Release, "/tmp/x.sock"),
            // S4: the override wins verbatim EVEN in dev — the load-bearing
            // guard: the integration harness injects TARMAC_SOCKET into debug
            // builds and must bypass the `dev/` insertion.
            (Some("/tmp/x.sock"), "/Users/eplin", Channel::Dev, "/tmp/x.sock"),
            // S9: an empty override is treated as unset → falls to the default.
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

    // S5: dev differs from release only by the inserted `/dev` segment — nothing
    // else moves. Pins the token name and that release is otherwise unchanged.
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

    // S6/S7/S9 for the state resolver.
    #[test]
    fn resolve_state_path_cases() {
        let cases: &[(Option<&str>, &str, Channel, &str)] = &[
            // S6: state, release == legacy flat path.
            (None, "/Users/eplin", Channel::Release,
             "/Users/eplin/Library/Application Support/tarmac/state.json"),
            // S7: state, dev carries the SAME `dev/` segment as the socket.
            (None, "/Users/eplin", Channel::Dev,
             "/Users/eplin/Library/Application Support/tarmac/dev/state.json"),
            // override wins verbatim for state too (parity with socket S3/S4).
            (Some("/tmp/s.json"), "/Users/eplin", Channel::Dev, "/tmp/s.json"),
            // empty override → dev default (S9 for state).
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

    // S7 by construction: socket and state share the per-channel directory, so a
    // dev daemon can never bind a dev socket while reading release state.
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

    // S8: the dev default appends a fixed 52-byte suffix to `home`
    // (/Library/Application Support/tarmac/dev/tarmacd.sock). So a 51-byte home
    // is 103 bytes (accepted at the `len < 104` cap) and a 52-byte home is 104
    // (rejected). The pure resolver only emits the string, so the Rust test
    // asserts the exact byte counts (the cap itself is enforced at `bind`).
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

    // S10: the channel label maps both arms (a swapped or constant label fails).
    #[test]
    fn channel_label_maps_both() {
        assert_eq!(channel_label(Channel::Release), "release");
        assert_eq!(channel_label(Channel::Dev), "dev");
    }

    // HelloOk.daemon_version / daemon_pid are additive: None omits the key on the
    // wire; a key-less HelloOk decodes both as None; Some values round-trip.
    #[test]
    fn hello_ok_daemon_version_additive() {
        let none_keyed = Msg::HelloOk { v: 1, daemon_version: None, daemon_pid: None };
        let bytes = encode(&none_keyed).unwrap();
        // The encoded bytes must not contain either optional key string.
        assert!(
            !bytes.windows(14).any(|w| w == b"daemon_version"),
            "None must omit the daemon_version key on the wire"
        );
        assert!(
            !bytes.windows(10).any(|w| w == b"daemon_pid"),
            "None must omit the daemon_pid key on the wire"
        );
        // Round-trip None → None.
        assert_eq!(roundtrip(&none_keyed), none_keyed);
        // A key-less wire frame decodes both as None.
        let Msg::HelloOk { daemon_version, daemon_pid, .. } = decode(&bytes).unwrap() else {
            panic!("expected hello_ok")
        };
        assert_eq!(daemon_version, None);
        assert_eq!(daemon_pid, None);
        // Some values round-trip.
        let with_vals = Msg::HelloOk { v: 1, daemon_version: Some("0.1.0".into()), daemon_pid: Some(4242) };
        assert_eq!(roundtrip(&with_vals), with_vals);
    }
}
