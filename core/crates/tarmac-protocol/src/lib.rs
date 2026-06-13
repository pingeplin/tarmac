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
    },
    Ack,
    Err {
        msg: String,
    },
    Open {
        path: String,
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
    },
    Restore {
        docs: Vec<DocEntry>,
        #[serde(default)]
        tiles: Vec<Tile>,
        // v4 board additive key (optional; missing => nil): persisted viewport.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        board: Option<BoardViewport>,
    },
    SpawnTerm {
        term_id: String,
        cols: u16,
        rows: u16,
        cwd: Option<String>,
        cmd: Option<Vec<String>>,
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
    // Unknown message types are ignored, not fatal (protocol rule).
    #[serde(other)]
    Unknown,
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
        }
    }

    // Geometry-less tiles (M1 shape): v4 x/y/w/h/z default to None, so these
    // encode/decode exactly as M1 frames did.
    fn term_tile() -> Tile {
        Tile { kind: "term".into(), path: None, x: None, y: None, w: None, h: None, z: None }
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
                }],
                board: Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }),
            },
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
            Msg::Restore { docs: vec![m0_entry("/a.md", "cli", None)], tiles: vec![], board: None }
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
            }],
            board: Some(BoardViewport { zoom: 0.5, cx: 10.0, cy: 20.0 }),
        };
        assert_eq!(roundtrip(&msg), msg);
    }

    #[test]
    fn repo_color_index_matches_theme_hash() {
        // Reference values from docs/m1/crib-state.md §1.2 (app's Theme.swift FNV-1a).
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
            Msg::SpawnTerm { term_id: "t1".into(), cols: 80, rows: 24, cwd: None, cmd: None }
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
            Msg::SpawnTerm { term_id: "t1".into(), cols: 80, rows: 24, cwd: None, cmd: None }
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
            Msg::HelloOk { v: 1 },
            Msg::Ack,
            Msg::Err { msg: "boom".into() },
            Msg::Open { path: "/tmp/a.md".into() },
            Msg::DocRead { path: "/tmp/a.md".into() },
            Msg::Layout {
                dock: vec!["/a.md".into(), "/b.md".into()],
                tiles: vec![term_tile(), doc_tile("/b.md")],
                board: None,
            },
            Msg::Layout { dock: vec![], tiles: vec![], board: None },
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
                    },
                    Tile {
                        kind: "doc".into(),
                        path: Some("/b.md".into()),
                        x: Some(648.0),
                        y: Some(140.0),
                        w: Some(392.0),
                        h: Some(310.0),
                        z: Some(1),
                    },
                ],
                board: Some(BoardViewport { zoom: 0.82, cx: 640.0, cy: 360.0 }),
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
                    },
                ],
                tiles: vec![term_tile()],
                board: Some(BoardViewport { zoom: 1.0, cx: 0.0, cy: 0.0 }),
            },
            Msg::SpawnTerm {
                term_id: "t1".into(),
                cols: 120,
                rows: 40,
                cwd: Some("/tmp".into()),
                cmd: Some(vec!["/bin/echo".into(), "hi".into()]),
            },
            Msg::SpawnTerm { term_id: "t2".into(), cols: 80, rows: 24, cwd: None, cmd: None },
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
            }),
            Msg::FileEvent { path: "/a.md".into(), mtime_ms: 1_765_432_100_123 },
        ];
        for m in msgs {
            assert_eq!(roundtrip(&m), m, "roundtrip failed for {m:?}");
        }
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
}
