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

fn term_tile() -> Tile {
    Tile { kind: "term".into(), ..Default::default() }
}

fn doc_tile(path: &str) -> Tile {
    Tile { kind: "doc".into(), path: Some(path.into()), ..term_tile() }
}

fn layout(dock: &[&str], tiles: Vec<Tile>) -> Msg {
    Msg::Layout { dock: dock.iter().map(|p| p.to_string()).collect(), tiles, board: None, board_id: None }
}

/// An 80x24 spawn with no cwd and no cmd.
fn spawn_term(term_id: &str, board_id: Option<&str>, inherit_cwd_from: Option<&str>) -> Msg {
    Msg::SpawnTerm {
        term_id: term_id.into(),
        cols: 80,
        rows: 24,
        cwd: None,
        cmd: None,
        board_id: board_id.map(str::to_string),
        inherit_cwd_from: inherit_cwd_from.map(str::to_string),
    }
}

fn hello_ok(
    daemon_version: Option<&str>,
    daemon_pid: Option<u32>,
    app_version: Option<&str>,
    app_connected: Option<bool>,
) -> Msg {
    Msg::HelloOk {
        v: 1,
        daemon_version: daemon_version.map(str::to_string),
        daemon_pid,
        app_version: app_version.map(str::to_string),
        app_connected,
    }
}

fn has(bytes: &[u8], needle: &[u8]) -> bool {
    bytes.windows(needle.len()).any(|w| w == needle)
}

fn roundtrip(m: &Msg) -> Msg {
    decode(&encode(m).unwrap()).unwrap()
}

/// Conformance vector 6: a layout with no `board`, no `board_id`, and two tiles
/// that carry no geometry.
const VECTOR_6: &str = "83 a1 74 a6 6c 61 79 6f 75 74 \
     a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64 \
     a5 74 69 6c 65 73 92 \
     81 a4 6b 69 6e 64 a4 74 65 72 6d \
     82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64";

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
        Msg::Hello { role: "app".into(), v: 1, app_version: None },
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
    assert_vector(
        "82 a1 74 aa 74 65 72 6d 5f 63 6c 6f 73 65 \
         a7 74 65 72 6d 5f 69 64 a2 74 31",
        Msg::TermClose { term_id: "t1".into() },
    );
}

#[test]
fn conformance_vector_10_doc_close() {
    assert_vector(
        "82 a1 74 a9 64 6f 63 5f 63 6c 6f 73 65 \
         a4 70 61 74 68 a5 2f 61 2e 6d 64",
        Msg::DocClose { path: "/a.md".into() },
    );
}

#[test]
fn conformance_vector_11_doc_refresh() {
    assert_vector(
        "82 a1 74 ab 64 6f 63 5f 72 65 66 72 65 73 68 \
         a4 70 61 74 68 a5 2f 61 2e 6d 64",
        Msg::DocRefresh { path: "/a.md".into() },
    );
}

#[test]
fn conformance_vector_12_scrollback_request() {
    assert_vector(
        "82 a1 74 b2 73 63 72 6f 6c 6c 62 61 63 6b 5f 72 65 71 75 65 73 74 \
         a7 74 65 72 6d 5f 69 64 a2 74 31",
        Msg::ScrollbackRequest { term_id: "t1".into() },
    );
}

#[test]
fn conformance_vector_13_scrollback() {
    // `bytes` rides the msgpack bin family (c4), like input/output.
    assert_vector(
        "83 a1 74 aa 73 63 72 6f 6c 6c 62 61 63 6b \
         a7 74 65 72 6d 5f 69 64 a2 74 31 \
         a5 62 79 74 65 73 c4 03 68 69 0a",
        Msg::Scrollback { term_id: "t1".into(), bytes: b"hi\n".to_vec() },
    );
}

#[test]
fn scrollback_reply_round_trips_empty_bytes() {
    // The daemon always answers, even with an empty ring — the empty reply
    // must survive the codec so the app can stop awaiting.
    let m = Msg::Scrollback { term_id: "t1".into(), bytes: Vec::new() };
    assert_eq!(roundtrip(&m), m);
}

#[test]
fn m0_shaped_doc_opened_decodes_with_defaults() {
    // {t:"doc_opened", path:"/a.md", via:"cli"} — a daemon that predates the optional keys
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
    // No `board` key and geometry-less tiles must decode to all-None geometry
    // and board None.
    assert_eq!(
        decode(&unhex(VECTOR_6)).unwrap(),
        layout(&["/a.md"], vec![term_tile(), doc_tile("/a.md")])
    );
}

#[test]
fn v4_board_keys_decode_from_wire() {
    // {t:"layout", dock:[], tiles:[{kind:"doc", path:"/a.md", x:1.0, y:2.0,
    //  w:3.0, h:4.0, z:5}], board:{zoom:0.5, cx:10.0, cy:20.0}}
    let msg = Msg::Layout {
        dock: vec![],
        tiles: vec![Tile {
            x: Some(1.0),
            y: Some(2.0),
            w: Some(3.0),
            h: Some(4.0),
            z: Some(5),
            ..doc_tile("/a.md")
        }],
        board: Some(BoardViewport { zoom: 0.5, cx: 10.0, cy: 20.0 }),
        board_id: None,
    };
    assert_eq!(roundtrip(&msg), msg);
}

// A tile carrying loose + shelf, an entry carrying term_id and an open
// carrying term_id all round-trip.
#[test]
fn phase3_loose_shelf_and_term_id_roundtrip() {
    // A shelf-parked, gravity-detached doc tile (no geometry).
    let shelf_tile = Tile { loose: Some(true), shelf: Some(true), ..doc_tile("/a.md") };
    let parked = layout(&["/a.md"], vec![shelf_tile]);
    assert_eq!(roundtrip(&parked), parked);

    // A doc entry carrying its opener term_id.
    let entry = DocEntry {
        read: false,
        last_opened_ms: Some(1),
        term_id: Some("term-42".into()),
        ..m0_entry("/a.md", "cli", None)
    };
    assert_eq!(roundtrip(&Msg::DocOpened(entry.clone())), Msg::DocOpened(entry));

    // An open carrying the calling term_id.
    let open = Msg::Open { path: "/a.md".into(), term_id: Some("term-42".into()), board_id: None };
    assert_eq!(roundtrip(&open), open);
}

// A terminal tile's `term_id` round-trips, and a multi-terminal layout
// preserves two distinct term tile ids in order.
#[test]
fn phase5b_term_tile_term_id_roundtrip() {
    let t1 = Tile { term_id: Some("t1".into()), ..term_tile() };
    let t2 = Tile { term_id: Some("t2".into()), x: Some(600.0), y: Some(80.0), ..term_tile() };
    let sent = layout(&["/a.md"], vec![t1, t2, doc_tile("/a.md")]);
    let rt = roundtrip(&sent);
    assert_eq!(rt, sent);
    let Msg::Layout { tiles, .. } = rt else { panic!("expected layout") };
    assert_eq!(tiles[0].term_id.as_deref(), Some("t1"));
    assert_eq!(tiles[1].term_id.as_deref(), Some("t2"));
    assert_eq!(tiles[2].term_id, None); // a doc tile carries no term_id
}

// A keyless term tile (legacy single-terminal layout) decodes term_id == None
// and encodes to the same bytes as before the key existed.
#[test]
fn phase5b_keyless_term_tile_decodes_to_none() {
    let Msg::Layout { tiles, .. } = roundtrip(&layout(&[], vec![term_tile()])) else {
        panic!("expected layout")
    };
    assert_eq!(tiles[0].term_id, None);
    // A bare term tile serializes to {kind:"term"}: `skip_serializing_if`
    // omits every None.
    let bytes = unhex("81 a4 6b 69 6e 64 a4 74 65 72 6d");
    assert_eq!(rmp_serde::to_vec_named(&term_tile()).unwrap(), bytes);
}

// A layout / restore carrying a `board_id` round-trips with the id intact.
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
    let Msg::Layout { board_id, .. } = rt else { panic!("expected layout") };
    assert_eq!(board_id.as_deref(), Some("board-1"));

    let restore = Msg::Restore {
        docs: vec![m0_entry("/a.md", "cli", None)],
        tiles: vec![term_tile()],
        board: Some(BoardViewport { zoom: 1.0, cx: 0.0, cy: 0.0 }),
        board_id: Some("board-2".into()),
        live_terms: vec![],
    };
    assert_eq!(roundtrip(&restore), restore);
}

// A board_id-less layout decodes board_id == None, and a None-keyed layout
// re-encodes without a `board_id` key, so a single-board sender's frame is
// unchanged.
#[test]
fn m3_keyless_layout_decodes_board_id_none() {
    let bytes = unhex(VECTOR_6);
    let Msg::Layout { board_id, .. } = decode(&bytes).unwrap() else { panic!("not layout") };
    assert_eq!(board_id, None);

    // The re-encoded frame is byte-identical to the input (no board_id key).
    let none_keyed = layout(&["/a.md"], vec![term_tile(), doc_tile("/a.md")]);
    assert_eq!(encode(&none_keyed).unwrap(), bytes);
}

// A board_list decodes from the wire (a board with no name omits the key and
// decodes None); board_switch / board_create round-trip.
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

// BoardMeta.running round-trips; None omits the key, distinct from an
// explicit running:0.
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

    // running:None omits the key; an explicit running:0 is a real key, so
    // the two encodings differ.
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

// A restore carrying `live_terms` round-trips; one without omits the key, so
// earlier restores decode an empty list and re-encode byte-identically.
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

    // An empty live_terms omits the key; a non-empty list is a real key, so
    // the encodings differ.
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

// board_rename / board_delete round-trip (named and empty-name rename), and
// a hand-built wire frame decodes by tag.
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

// A keyless spawn_term / open decodes board_id None.
#[test]
fn m3_keyless_spawn_and_open_decode_board_id_none() {
    // {t:"spawn_term", term_id:"t1", cols:80, rows:24} — no board_id key.
    let spawn = unhex(
        "84 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d \
         a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18",
    );
    assert_eq!(decode(&spawn).unwrap(), spawn_term("t1", None, None));

    // {t:"open", path:"/a.md"} — no term_id / board_id keys.
    let open = unhex("82 a1 74 a4 6f 70 65 6e a4 70 61 74 68 a5 2f 61 2e 6d 64");
    assert_eq!(
        decode(&open).unwrap(),
        Msg::Open { path: "/a.md".into(), term_id: None, board_id: None }
    );
}

// inherit_cwd_from round-trips and, unlike cwd/cmd, is on the wire only when
// Some, so a spawn that never sets it keeps its earlier bytes.
#[test]
fn inherit_cwd_from_roundtrips_and_omits_when_none() {
    let with_hint = spawn_term("t1", None, Some("prime"));
    assert_eq!(roundtrip(&with_hint), with_hint);
    let encoded = encode(&with_hint).unwrap();
    assert!(
        has(&encoded, b"inherit_cwd_from"),
        "inherit_cwd_from key missing from encoded Some: {encoded:02x?}"
    );

    let encoded_none = encode(&spawn_term("t1", None, None)).unwrap();
    assert!(
        !has(&encoded_none, b"inherit_cwd_from"),
        "inherit_cwd_from key present despite None: {encoded_none:02x?}"
    );
}

// Key-less shapes still decode to None: a tile with no loose/shelf, an entry
// with no term_id, an open with no term_id.
#[test]
fn phase3_keyless_shapes_decode_to_none() {
    // {t:"open", path:"/a.md"} — an open with no term_id key.
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

    let Msg::Layout { tiles, .. } = decode(&unhex(VECTOR_6)).unwrap() else { panic!("not layout") };
    assert_eq!(tiles[0].loose, None);
    assert_eq!(tiles[0].shelf, None);
    assert_eq!(tiles[1].loose, None);
    assert_eq!(tiles[1].shelf, None);
}

#[test]
fn repo_color_index_matches_theme_hash() {
    // Pinned: a changed hash recolors docs users already saw.
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
    assert_eq!(decode(&bytes).unwrap(), spawn_term("t1", None, None));
}

#[test]
fn explicit_nil_optionals_decode_as_none() {
    // {t:"spawn_term", term_id:"t1", cols:80, rows:24, cwd:nil, cmd:nil}
    let bytes = unhex(
        "86 a1 74 aa 73 70 61 77 6e 5f 74 65 72 6d \
         a7 74 65 72 6d 5f 69 64 a2 74 31 a4 63 6f 6c 73 50 a4 72 6f 77 73 18 \
         a3 63 77 64 c0 a3 63 6d 64 c0",
    );
    assert_eq!(decode(&bytes).unwrap(), spawn_term("t1", None, None));
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
    assert!(has(&encoded, &needle), "bytes not bin-encoded: {encoded:02x?}");
}

#[test]
fn all_message_types_roundtrip() {
    let msgs = vec![
        Msg::Hello { role: "cli".into(), v: 1, app_version: None },
        Msg::Hello { role: "app".into(), v: 1, app_version: Some("9.9.9".into()) },
        hello_ok(None, None, None, None),
        Msg::Ack,
        Msg::Err { msg: "boom".into() },
        Msg::Open { path: "/tmp/a.md".into(), term_id: None, board_id: None },
        Msg::Open { path: "/tmp/a.md".into(), term_id: Some("t1".into()), board_id: None },
        Msg::DocRead { path: "/tmp/a.md".into() },
        layout(&["/a.md", "/b.md"], vec![term_tile(), doc_tile("/b.md")]),
        layout(&[], vec![]),
        // world-frame tiles + a board viewport
        Msg::Layout {
            dock: vec!["/b.md".into()],
            tiles: vec![
                Tile {
                    x: Some(92.0),
                    y: Some(108.0),
                    w: Some(470.0),
                    h: Some(330.0),
                    z: Some(0),
                    ..term_tile()
                },
                Tile {
                    x: Some(648.0),
                    y: Some(140.0),
                    w: Some(392.0),
                    h: Some(310.0),
                    z: Some(1),
                    loose: Some(true),
                    ..doc_tile("/b.md")
                },
                // A shelf doc tile: shelf:true, no geometry.
                Tile { loose: Some(true), shelf: Some(true), ..doc_tile("/c.md") },
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
            live_terms: vec!["t1".into()],
        },
        Msg::SpawnTerm {
            term_id: "t1".into(),
            cols: 120,
            rows: 40,
            cwd: Some("/tmp".into()),
            cmd: Some(vec!["/bin/echo".into(), "hi".into()]),
            board_id: None,
            inherit_cwd_from: None,
        },
        spawn_term("t2", None, None),
        // cwd absent but an inherit-cwd-from hint present
        spawn_term("t3", None, Some("t1")),
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
        Msg::TermProc { term_id: "t1".into(), name: "zsh".into(), pid: Some(4242) },
        Msg::TermProc { term_id: "t1".into(), name: "vim".into(), pid: None },
        Msg::Bell { term_id: "t1".into() },
        // board CRUD/list
        Msg::BoardList {
            boards: vec![
                BoardMeta { board_id: "board-0".into(), name: None, running: None },
                BoardMeta { board_id: "board-1".into(), name: Some("infra".into()), running: None },
            ],
            active: "board-1".into(),
        },
        Msg::BoardSwitch { board_id: "board-1".into() },
        Msg::BoardCreate,
        // board rename (named + cleared) / delete
        Msg::BoardRename { board_id: "board-1".into(), name: "infra".into() },
        Msg::BoardRename { board_id: "board-1".into(), name: String::new() },
        Msg::BoardDelete { board_id: "board-1".into() },
        Msg::TermClose { term_id: "t1".into() },
        // board_id on spawn/open
        spawn_term("t9", Some("board-1"), None),
        Msg::Open { path: "/a.md".into(), term_id: Some("t9".into()), board_id: Some("board-1".into()) },
        Msg::DocClose { path: "/tmp/a.md".into() },
        Msg::DocRefresh { path: "/tmp/a.md".into() },
    ];
    for m in msgs {
        assert_eq!(roundtrip(&m), m, "roundtrip failed for {m:?}");
    }
}

// term_proc round-trips with and without pid, a pid-less wire shape decodes
// to None, and bell round-trips.
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
    assert!(has(&encoded, &needle));
    assert_eq!(roundtrip(&m), m);
}

// HelloOk.daemon_version / daemon_pid: None omits the key on the wire, a
// key-less HelloOk decodes both as None, Some values round-trip.
#[test]
fn hello_ok_daemon_version_additive() {
    let none_keyed = hello_ok(None, None, None, None);
    let bytes = encode(&none_keyed).unwrap();
    assert!(!has(&bytes, b"daemon_version"), "None must omit the daemon_version key on the wire");
    assert!(!has(&bytes, b"daemon_pid"), "None must omit the daemon_pid key on the wire");
    assert_eq!(roundtrip(&none_keyed), none_keyed);
    let Msg::HelloOk { daemon_version, daemon_pid, .. } = decode(&bytes).unwrap() else {
        panic!("expected hello_ok")
    };
    assert_eq!(daemon_version, None);
    assert_eq!(daemon_pid, None);
    let with_vals = hello_ok(Some("0.1.0"), Some(4242), None, None);
    assert_eq!(roundtrip(&with_vals), with_vals);
}

// A None `app_version` on `hello` must leave conformance vector 2's *encoded
// bytes* untouched (map size included),
// not merely omit the key string. `assert_vector` only decodes, so byte
// equality is asserted here or nowhere. Deliberately stricter than
// protocol.md's "byte-exact output is not required": the claim being pinned
// is additivity, not a new wire requirement.
#[test]
fn hello_app_version_additive() {
    let vector_2 = unhex("83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01");
    let none_keyed = Msg::Hello { role: "app".into(), v: 1, app_version: None };
    assert_eq!(encode(&none_keyed).unwrap(), vector_2);
    assert_eq!(decode(&vector_2).unwrap(), none_keyed);
    // a value round-trips on `hello`
    let with_val = Msg::Hello { role: "app".into(), v: 1, app_version: Some("9.9.9".into()) };
    assert_eq!(roundtrip(&with_val), with_val);
}

// hello_ok's app_version + app_connected: None omits both keys, a key-less
// frame decodes both to None, and values round-trip.
#[test]
fn hello_ok_app_keys_additive() {
    let bytes = encode(&hello_ok(Some("0.1.0"), Some(1), None, None)).unwrap();
    assert!(!has(&bytes, b"app_version"), "None must omit the app_version key on the wire");
    assert!(!has(&bytes, b"app_connected"), "None must omit the app_connected key on the wire");
    let Msg::HelloOk { app_version, app_connected, .. } = decode(&bytes).unwrap() else {
        panic!("expected hello_ok")
    };
    assert_eq!(app_version, None);
    assert_eq!(app_connected, None);

    let with_vals = hello_ok(Some("0.1.0"), Some(4242), Some("8.8.8"), Some(true));
    assert_eq!(roundtrip(&with_vals), with_vals);
    // app_connected carries false distinctly from absent.
    let absent_app = hello_ok(Some("0.1.0"), Some(4242), None, Some(false));
    assert_eq!(roundtrip(&absent_app), absent_app);
}
