import XCTest
import TarmacKit

func hexData(_ hex: String) -> Data {
    let cleaned = hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined()
    precondition(cleaned.count % 2 == 0, "odd-length hex")
    var out = Data(capacity: cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        out.append(UInt8(cleaned[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// The mandatory conformance vectors from docs/protocol.md.
final class ConformanceTests: XCTestCase {
    private func assertRoundTrips(_ value: MsgPackValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try MsgPack.decode(MsgPack.encode(value)), value, file: file, line: line)
    }

    private func assertRoundTrips(_ message: Message, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message, file: file, line: line)
    }

    func testVector1Ack() throws {
        let payload = hexData("81 a1 74 a3 61 63 6b")
        let expected = MsgPackValue.map(["t": .string("ack")])

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), .ack)
        assertRoundTrips(expected)
        assertRoundTrips(Message.ack)
        // Byte-exact output is not required, but for this single-key map it holds.
        XCTAssertEqual(Message.ack.encodedPayload(), payload)
    }

    func testVector2Hello() throws {
        let payload = hexData("83 a1 74 a5 68 65 6c 6c 6f a4 72 6f 6c 65 a3 61 70 70 a1 76 01")
        let expected = MsgPackValue.map(["t": .string("hello"), "role": .string("app"), "v": .int(1)])

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), .hello(role: "app", v: 1))
        assertRoundTrips(expected)
        assertRoundTrips(Message.hello(role: "app", v: 1))
        // Our encoding must decode to the same structure as the vector (key order may differ).
        XCTAssertEqual(try MsgPack.decode(Message.hello(role: "app", v: 1).encodedPayload()), expected)
    }

    func testVector3Input() throws {
        let payload = hexData("""
            83 a1 74 a5 69 6e 70 75 74 a7 74 65 72 6d 5f 69 64 a2 74 31
            a5 62 79 74 65 73 c4 03 6c 73 0a
            """)
        let bytes = Data([0x6c, 0x73, 0x0a]) // "ls\n"
        let expected = MsgPackValue.map([
            "t": .string("input"),
            "term_id": .string("t1"),
            "bytes": .binary(bytes),
        ])

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), .input(termID: "t1", bytes: bytes))
        assertRoundTrips(expected)
        assertRoundTrips(Message.input(termID: "t1", bytes: bytes))
        XCTAssertEqual(try MsgPack.decode(Message.input(termID: "t1", bytes: bytes).encodedPayload()), expected)
    }

    func testVector4Resize() throws {
        let payload = hexData("""
            84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 63 6f 6c 73 78 a4 72 6f 77 73 28
            """)
        let expected = MsgPackValue.map([
            "t": .string("resize"),
            "term_id": .string("t1"),
            "cols": .int(120),
            "rows": .int(40),
        ])

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), .resize(termID: "t1", cols: 120, rows: 40))
        assertRoundTrips(expected)
        assertRoundTrips(Message.resize(termID: "t1", cols: 120, rows: 40))
        XCTAssertEqual(try MsgPack.decode(Message.resize(termID: "t1", cols: 120, rows: 40).encodedPayload()), expected)
    }

    func testVector5DocRead() throws {
        let payload = hexData("82 a1 74 a8 64 6f 63 5f 72 65 61 64 a4 70 61 74 68 a5 2f 61 2e 6d 64")
        let expected = MsgPackValue.map(["t": .string("doc_read"), "path": .string("/a.md")])

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), .docRead(path: "/a.md"))
        assertRoundTrips(expected)
        assertRoundTrips(Message.docRead(path: "/a.md"))
        XCTAssertEqual(try MsgPack.decode(Message.docRead(path: "/a.md").encodedPayload()), expected)
    }

    func testVector6Layout() throws {
        let payload = hexData("""
            83 a1 74 a6 6c 61 79 6f 75 74
            a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64
            a5 74 69 6c 65 73 92
            81 a4 6b 69 6e 64 a4 74 65 72 6d
            82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
            """)
        let expected = MsgPackValue.map([
            "t": .string("layout"),
            "dock": .array([.string("/a.md")]),
            "tiles": .array([
                .map(["kind": .string("term")]),
                .map(["kind": .string("doc"), "path": .string("/a.md")]),
            ]),
        ])
        let message = Message.layout(
            dock: ["/a.md"],
            tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/a.md")],
            board: nil,
            boardID: nil
        )

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), message)
        assertRoundTrips(expected)
        assertRoundTrips(message)
        XCTAssertEqual(try MsgPack.decode(message.encodedPayload()), expected)
    }

    func testVector7DocOpenedExtended() throws {
        let payload = hexData("""
            87 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64
            a4 70 61 74 68 a5 2f 61 2e 6d 64
            a3 76 69 61 a3 63 6c 69
            a4 72 65 70 6f a3 61 70 69
            aa 72 65 70 6f 5f 63 6f 6c 6f 72 03
            a4 72 65 61 64 c2
            ae 6c 61 73 74 5f 6f 70 65 6e 65 64 5f 6d 73 cf 00 00 01 90 00 c7 9c 00
            """)
        let expected = MsgPackValue.map([
            "t": .string("doc_opened"),
            "path": .string("/a.md"),
            "via": .string("cli"),
            "repo": .string("api"),
            "repo_color": .int(3),
            "read": .bool(false),
            "last_opened_ms": .int(1_718_000_000_000),
        ])
        let message = Message.docOpened(doc: RestoreDoc(
            path: "/a.md",
            via: "cli",
            repo: "api",
            repoColor: 3,
            read: false,
            lastOpenedMs: 1_718_000_000_000
        ))

        XCTAssertEqual(try MsgPack.decode(payload), expected)
        XCTAssertEqual(try Message.decode(payload: payload), message)
        assertRoundTrips(expected)
        assertRoundTrips(message)
        XCTAssertEqual(try MsgPack.decode(message.encodedPayload()), expected)
    }

    /// v4 board additive keys (docs/protocol.md "v4 board additive keys"):
    /// a layout whose doc tile carries x,y,w,h,z and whose top level carries a
    /// board {zoom,cx,cy}. Generated by the Rust encoder (to_vec_named).
    func testVector8V4BoardKeys() throws {
        let payload = hexData("""
            84 a1 74 a6 6c 61 79 6f 75 74
            a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64
            a5 74 69 6c 65 73 91
            87 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
            a1 78 cb 40 5e 00 00 00 00 00 00
            a1 79 cb 40 54 00 00 00 00 00 00
            a1 77 cb 40 7d 60 00 00 00 00 00
            a1 68 cb 40 74 a0 00 00 00 00 00
            a1 7a 02
            a5 62 6f 61 72 64 83
            a4 7a 6f 6f 6d cb 3f ea 3d 70 a3 d7 0a 3d
            a2 63 78 cb 40 84 00 00 00 00 00 00
            a2 63 79 cb 40 76 80 00 00 00 00 00
            """)
        let message = Message.layout(
            dock: ["/a.md"],
            tiles: [LayoutTile(kind: "doc", path: "/a.md", x: 120, y: 80, w: 470, h: 330, z: 2)],
            board: BoardViewport(zoom: 0.82, cx: 640, cy: 360),
            boardID: nil
        )

        XCTAssertEqual(try Message.decode(payload: payload), message)
        // Round-trips through our own encoder too (key order may differ).
        assertRoundTrips(message)
        XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
    }

    /// An M1 layout (geometry-less tiles, no `board` key) must still decode
    /// under v4 with all-nil tile geometry and a nil board (additive guarantee).
    func testM1LayoutDecodesWithNilBoardAndGeometry() throws {
        // Conformance vector 6 verbatim.
        let payload = hexData("""
            83 a1 74 a6 6c 61 79 6f 75 74
            a4 64 6f 63 6b 91 a5 2f 61 2e 6d 64
            a5 74 69 6c 65 73 92
            81 a4 6b 69 6e 64 a4 74 65 72 6d
            82 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
            """)
        let decoded = try Message.decode(payload: payload)
        XCTAssertEqual(
            decoded,
            .layout(
                dock: ["/a.md"],
                tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/a.md")],
                board: nil,
                boardID: nil
            )
        )
        // The decoded tiles must report nil geometry.
        guard case .layout(_, let tiles, let board, _) = decoded else { return XCTFail("not a layout") }
        XCTAssertNil(board)
        XCTAssertNil(tiles[0].x)
        XCTAssertNil(tiles[1].z)
        // Phase 3 fields default to nil on an M1 tile (additive guarantee).
        XCTAssertNil(tiles[0].loose)
        XCTAssertNil(tiles[1].shelf)
    }

    /// v4 Phase 3 (additive): a Tile with loose+shelf, a DocEntry with term_id,
    /// and an Open with term_id each survive an encode→decode round-trip; and
    /// the key-less M1 shapes still decode to nil.
    func testPhase3LooseShelfAndTermIDRoundTrip() throws {
        // A shelf-parked, gravity-detached doc tile (no geometry).
        let shelfLayout = Message.layout(
            dock: ["/a.md"],
            tiles: [LayoutTile(kind: "doc", path: "/a.md", loose: true, shelf: true)],
            board: nil,
            boardID: nil
        )
        XCTAssertEqual(try Message.decode(payload: shelfLayout.encodedPayload()), shelfLayout)

        // A doc entry carrying its opener term_id.
        let opened = Message.docOpened(doc: RestoreDoc(
            path: "/a.md",
            via: "cli",
            read: false,
            lastOpenedMs: 1,
            termID: "term-42"
        ))
        XCTAssertEqual(try Message.decode(payload: opened.encodedPayload()), opened)

        // An open carrying the calling term_id.
        let open = Message.open(path: "/a.md", termID: "term-42")
        XCTAssertEqual(try Message.decode(payload: open.encodedPayload()), open)

        // Encoders must emit the keys with the documented wire names.
        let tileMap = try MsgPack.decode(shelfLayout.encodedPayload())
        guard case .array(let tiles)? = tileMap["tiles"], case .map(let t0)? = tiles.first else {
            return XCTFail("layout tiles did not encode as an array of maps")
        }
        XCTAssertEqual(t0["loose"], .bool(true))
        XCTAssertEqual(t0["shelf"], .bool(true))
        let entryMap = try MsgPack.decode(opened.encodedPayload())
        XCTAssertEqual(entryMap["term_id"], .string("term-42"))
        let openMap = try MsgPack.decode(open.encodedPayload())
        XCTAssertEqual(openMap["term_id"], .string("term-42"))
    }

    /// Key-less M1/M0 shapes decode to nil for the Phase 3 fields.
    func testPhase3KeylessShapesDecodeToNil() throws {
        // {t:"open", path:"/a.md"} — an M0/M1 open with no term_id key.
        let openBytes = hexData("82 a1 74 a4 6f 70 65 6e a4 70 61 74 68 a5 2f 61 2e 6d 64")
        XCTAssertEqual(try Message.decode(payload: openBytes), .open(path: "/a.md", termID: nil))

        // {t:"doc_opened", path:"/a.md", via:"cli"} — no term_id key.
        let openedBytes = hexData("""
            83 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64
            a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69
            """)
        guard case .docOpened(let doc) = try Message.decode(payload: openedBytes) else {
            return XCTFail("not doc_opened")
        }
        XCTAssertNil(doc.termID)
    }

    /// M2 honest signals (additive daemon → app types): term_proc (with/without
    /// pid) and bell decode from the wire and survive an encode→decode trip.
    func testM2TermProcAndBell() throws {
        // {t:"term_proc", term_id:"t1", name:"vim"} — a pid-less wire shape.
        let procBytes = hexData("""
            83 a1 74 a9 74 65 72 6d 5f 70 72 6f 63
            a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 6e 61 6d 65 a3 76 69 6d
            """)
        XCTAssertEqual(
            try Message.decode(payload: procBytes),
            .termProc(termID: "t1", name: "vim", pid: nil)
        )

        let withPid = Message.termProc(termID: "t1", name: "claude", pid: 99)
        XCTAssertEqual(try Message.decode(payload: withPid.encodedPayload()), withPid)
        let noPid = Message.termProc(termID: "t1", name: "claude", pid: nil)
        XCTAssertEqual(try Message.decode(payload: noPid.encodedPayload()), noPid)
        // The pid key is emitted only when present (missing ⇒ nil).
        let noPidMap = try MsgPack.decode(noPid.encodedPayload())
        XCTAssertNil(noPidMap["pid"])
        let withPidMap = try MsgPack.decode(withPid.encodedPayload())
        XCTAssertEqual(withPidMap["pid"], .int(99))

        // {t:"bell", term_id:"t1"} from the wire.
        let bellBytes = hexData("82 a1 74 a4 62 65 6c 6c a7 74 65 72 6d 5f 69 64 a2 74 31")
        XCTAssertEqual(try Message.decode(payload: bellBytes), .bell(termID: "t1"))
        let bell = Message.bell(termID: "t1")
        XCTAssertEqual(try Message.decode(payload: bell.encodedPayload()), bell)
    }

    // M3 ("strips = boards"): the same board_list wire vector the Rust
    // conformance test pins (cross-language agreement); a name-less board omits
    // the key and decodes nil; board_switch / board_create round-trip.
    func testM3BoardMessages() throws {
        let listBytes = hexData("""
            83 a1 74 aa 62 6f 61 72 64 5f 6c 69 73 74
            a6 62 6f 61 72 64 73 92
            81 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 30
            82 a8 62 6f 61 72 64 5f 69 64 a7 62 6f 61 72 64 2d 31
            a4 6e 61 6d 65 a5 69 6e 66 72 61
            a6 61 63 74 69 76 65 a7 62 6f 61 72 64 2d 31
            """)
        XCTAssertEqual(
            try Message.decode(payload: listBytes),
            .boardList(
                boards: [
                    BoardMeta(boardID: "board-0", name: nil),
                    BoardMeta(boardID: "board-1", name: "infra"),
                ],
                active: "board-1"
            )
        )

        let sw = Message.boardSwitch(boardID: "board-2")
        XCTAssertEqual(try Message.decode(payload: sw.encodedPayload()), sw)
        XCTAssertEqual(try Message.decode(payload: Message.boardCreate.encodedPayload()), .boardCreate)
        // A name-less board emits no `name` key.
        let listOut = try MsgPack.decode(
            Message.boardList(boards: [BoardMeta(boardID: "board-0")], active: "board-0").encodedPayload()
        )
        if case .array(let arr)? = listOut["boards"], case .map(let m0)? = arr.first {
            XCTAssertNil(m0["name"], "a name-less board omits the name key")
        } else {
            XCTFail("board_list did not encode a boards array")
        }
    }
}

final class MessageDecodingRulesTests: XCTestCase {
    func testKeyOrderDoesNotMatter() throws {
        // {v:1, role:"app", t:"hello"} — same fields, reversed order.
        let payload = hexData("83 a1 76 01 a4 72 6f 6c 65 a3 61 70 70 a1 74 a5 68 65 6c 6c 6f")
        XCTAssertEqual(try Message.decode(payload: payload), .hello(role: "app", v: 1))
    }

    func testUnknownKeysAreIgnored() throws {
        // {t:"ack", x:99}
        let payload = hexData("82 a1 74 a3 61 63 6b a1 78 63")
        XCTAssertEqual(try Message.decode(payload: payload), .ack)
    }

    func testUnknownMessageTypeDecodesAsUnknown() throws {
        // {t:"frobnicate"}
        let value = MsgPackValue.map(["t": .string("frobnicate")])
        XCTAssertEqual(try Message.decode(value), .unknown(type: "frobnicate"))
    }

    func testAnyCorrectIntegerWidthIsAccepted() throws {
        // resize with cols as uint16 (0xcd 0078) and rows as uint8 (0xcc 28).
        let payload = hexData("""
            84 a1 74 a6 72 65 73 69 7a 65 a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 63 6f 6c 73 cd 00 78 a4 72 6f 77 73 cc 28
            """)
        XCTAssertEqual(try Message.decode(payload: payload), .resize(termID: "t1", cols: 120, rows: 40))
    }

    func testMissingOptionalFieldsDecodeAsNil() throws {
        XCTAssertEqual(
            try Message.decode(.map(["t": .string("exit"), "term_id": .string("t1")])),
            .exit(termID: "t1", code: nil)
        )
        XCTAssertEqual(
            try Message.decode(.map([
                "t": .string("spawn_term"),
                "term_id": .string("t1"),
                "cols": .int(80),
                "rows": .int(24),
            ])),
            .spawnTerm(termID: "t1", cols: 80, rows: 24, cwd: nil, cmd: nil)
        )
    }

    func testExplicitNilOptionalFieldsDecodeAsNil() throws {
        XCTAssertEqual(
            try Message.decode(.map(["t": .string("exit"), "term_id": .string("t1"), "code": .nil])),
            .exit(termID: "t1", code: nil)
        )
    }

    func testMissingRequiredFieldThrows() {
        XCTAssertThrowsError(try Message.decode(.map(["t": .string("input"), "term_id": .string("t1")])))
        XCTAssertThrowsError(try Message.decode(.map(["role": .string("app")])))
    }

    func testBytesEncodeAsBinFamily() throws {
        let payload = Message.input(termID: "t1", bytes: Data("ls\n".utf8)).encodedPayload()
        guard case .binary(let data)? = try MsgPack.decode(payload)["bytes"] else {
            return XCTFail("bytes did not decode as msgpack bin family")
        }
        XCTAssertEqual(data, Data("ls\n".utf8))
    }

    func testRestoreRoundTrip() throws {
        let message = Message.restore(
            docs: [
                RestoreDoc(path: "/tmp/a.md", via: "cli", lastChangedMs: 1_765_432_100_123),
                RestoreDoc(
                    path: "/tmp/b.md",
                    via: "user",
                    repo: "payments-api",
                    repoRoot: "/Users/x/payments-api",
                    repoColor: 3,
                    read: false,
                    lastChangedMs: nil,
                    lastOpenedMs: 1_765_432_100_456
                ),
            ],
            tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/tmp/b.md")],
            board: nil,
            boardID: nil
        )
        XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
    }

    func testM0ShapedDocEntryDecodesWithDefaults() throws {
        // {t:"doc_opened", path:"/a.md", via:"cli"} — exactly what an M0 daemon sends.
        let docOpened = hexData("""
            83 a1 74 aa 64 6f 63 5f 6f 70 65 6e 65 64
            a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69
            """)
        XCTAssertEqual(
            try Message.decode(payload: docOpened),
            .docOpened(doc: RestoreDoc(path: "/a.md", via: "cli"))
        )

        // {t:"restore", docs:[{path:"/a.md", via:"cli", last_changed_ms:nil}]} — no tiles key.
        let restore = hexData("""
            82 a1 74 a7 72 65 73 74 6f 72 65 a4 64 6f 63 73 91
            83 a4 70 61 74 68 a5 2f 61 2e 6d 64 a3 76 69 61 a3 63 6c 69
            af 6c 61 73 74 5f 63 68 61 6e 67 65 64 5f 6d 73 c0
            """)
        XCTAssertEqual(
            try Message.decode(payload: restore),
            .restore(docs: [RestoreDoc(path: "/a.md", via: "cli")], tiles: [], board: nil, boardID: nil)
        )
    }

    func testAllMessagesRoundTrip() throws {
        let messages: [Message] = [
            .hello(role: "cli", v: 1),
            .helloOK(v: 1),
            .ack,
            .err(msg: "nope"),
            .open(path: "/abs/x.md", termID: nil),
            .open(path: "/abs/x.md", termID: "t1"),
            .docRead(path: "/abs/x.md"),
            .layout(dock: [], tiles: [], board: nil, boardID: nil),
            .layout(
                dock: ["/abs/x.md", "/abs/y.md"],
                tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/abs/y.md")],
                board: nil,
                boardID: nil
            ),
            // v4 layout carrying world-frame tiles + a board viewport.
            .layout(
                dock: ["/abs/y.md"],
                tiles: [
                    LayoutTile(kind: "term", x: 92, y: 108, w: 470, h: 330, z: 0),
                    LayoutTile(kind: "doc", path: "/abs/y.md", x: 648, y: 140, w: 392, h: 310, z: 1),
                ],
                board: BoardViewport(zoom: 0.82, cx: 640, cy: 360),
                boardID: nil
            ),
            // M3 additive: a layout/restore stamped with a board_id round-trips.
            .layout(
                dock: ["/abs/y.md"],
                tiles: [LayoutTile(kind: "term", x: 1, y: 2, w: 3, h: 4, z: 0, termID: "t1")],
                board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
                boardID: "board-1"
            ),
            .restore(docs: [], tiles: [], board: nil, boardID: nil),
            .restore(
                docs: [RestoreDoc(path: "/abs/y.md", via: "user")],
                tiles: [LayoutTile(kind: "doc", path: "/abs/y.md", x: 12.5, y: 24, w: 300, h: 200, z: 2)],
                board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
                boardID: nil
            ),
            .restore(
                docs: [RestoreDoc(path: "/abs/y.md", via: "user", termID: "t1")],
                tiles: [LayoutTile(kind: "term", x: 0, y: 0, w: 1, h: 1, z: 0, termID: "t1")],
                board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
                boardID: "board-2"
            ),
            .spawnTerm(termID: "u-1", cols: 191, rows: 49, cwd: "/Users/x", cmd: ["/bin/echo", "hi"]),
            .input(termID: "u-1", bytes: Data([0x03])),
            .resize(termID: "u-1", cols: 80, rows: 24),
            .output(termID: "u-1", bytes: Data(repeating: 0xab, count: 70_000)),
            .exit(termID: "u-1", code: -1),
            .exit(termID: "u-1", code: nil),
            .docOpened(doc: RestoreDoc(
                path: "/abs/x.md",
                via: "user",
                repo: "infra",
                repoRoot: "/Users/x/infra",
                repoColor: 1,
                read: true,
                lastOpenedMs: 1_765_432_100_123
            )),
            .fileEvent(path: "/abs/x.md", mtimeMs: 1_765_432_100_123),
            .termProc(termID: "u-1", name: "zsh", pid: 4242),
            .termProc(termID: "u-1", name: "vim", pid: nil),
            .bell(termID: "u-1"),
        ]
        for message in messages {
            XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
        }
    }
}
