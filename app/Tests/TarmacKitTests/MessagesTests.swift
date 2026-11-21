import XCTest
@testable import TarmacKit

/// What `Message` refuses in a frame it knows (spec 2611.0003 S41).
final class MessagesTests: XCTestCase {
    private func decoded(_ fields: [String: MsgPackValue]) throws -> Message {
        try Message.decode(payload: MsgPack.encode(.map(fields)))
    }

    func testS41ADocEventDecodesWithItsPathAndValue() throws {
        XCTAssertEqual(
            try decoded(["t": .string("doc_event"), "path": .string("/a/dash.html"), "value": .string("[1]")]),
            .docEvent(path: "/a/dash.html", value: "[1]")
        )
    }

    func testS41ADocEventWithNoValueIsRefused() {
        for fields: [String: MsgPackValue] in [
            ["t": .string("doc_event"), "path": .string("/a/dash.html")],
            ["t": .string("doc_event"), "path": .string("/a/dash.html"), "value": .nil],
        ] {
            XCTAssertThrowsError(try decoded(fields)) { error in
                XCTAssertEqual(error as? MessageError, .missingField("value"))
            }
        }
    }

    func testS41ADocEventWhoseValueIsNoStringIsRefused() {
        for value: MsgPackValue in [.int(1), .binary(Data("[1]".utf8)), .array([.string("[1]")])] {
            XCTAssertThrowsError(
                try decoded(["t": .string("doc_event"), "path": .string("/a/dash.html"), "value": value])
            ) { error in
                XCTAssertEqual(error as? MessageError, .badField("value"), "\(value)")
            }
        }
    }

    // 2611.0013 S37: an older daemon's frame (vector 22's bytes) has no place.
    func testS37ATermReportWithNoBoardAndNoCwdDecodesWithBothNil() throws {
        let v22 = hexData("""
            87 a1 74 ab 74 65 72 6d 5f 72 65 70 6f 72 74 a7 74 65 72 6d 5f 69 64 a2 74 31
            a4 6b 69 6e 64 a4 64 6f 6e 65 a4 74 65 78 74 a2 6f 6b
            a5 61 74 5f 6d 73 cf 00 00 01 8b cf e5 68 00
            a4 70 72 6f 63 a6 63 6c 61 75 64 65 a4 72 65 61 64 c3
            """)
        guard case .termReport(_, _, _, _, _, _, let boardID, let cwd) = try Message.decode(payload: v22) else {
            return XCTFail("not a term_report")
        }
        XCTAssertNil(boardID)
        XCTAssertNil(cwd)
    }

    // 2611.0013 S15: a bell and an exit with no board, and a report with no
    // place, write no key for it.
    func testANilBoardAndANilCwdPutNoKeyOnTheWire() throws {
        let frames: [Message] = [
            .bell(termID: "t1"),
            .exit(termID: "t1", code: 3),
            .termReport(termID: "t1", kind: "done", text: nil, atMs: 1, proc: nil, read: false),
        ]
        for frame in frames {
            let keys = try XCTUnwrap(MsgPack.decode(frame.encodedPayload()).mapValue).keys
            XCTAssertFalse(keys.contains("board_id"), "\(frame)")
            XCTAssertFalse(keys.contains("cwd"), "\(frame)")
        }
    }

    // MARK: What each decode site throws, key string and all

    private func assertRefused(
        _ value: MsgPackValue, _ expected: MessageError, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try Message.decode(value), "\(value)", file: file, line: line) { error in
            XCTAssertEqual(error as? MessageError, expected, file: file, line: line)
        }
    }

    func testTheTagIsMissingWhenAbsentNilOrNoString() {
        assertRefused(.array([]), .notAMap)
        assertRefused(.map(["path": .string("/a")]), .missingField("t"))
        assertRefused(.map(["t": .nil]), .missingField("t"))
        assertRefused(.map(["t": .int(1)]), .missingField("t"))
    }

    func testATopLevelFieldIsMissingWhenAbsentOrNilAndBadWhenMistyped() throws {
        assertRefused(.map(["t": .string("open")]), .missingField("path"))
        assertRefused(.map(["t": .string("open"), "path": .nil]), .missingField("path"))
        assertRefused(.map(["t": .string("open"), "path": .int(1)]), .badField("path"))
        assertRefused(.map(["t": .string("open"), "path": .string("/a"), "term_id": .int(1)]), .badField("term_id"))
        XCTAssertEqual(
            try Message.decode(.map(["t": .string("open"), "path": .string("/a"), "term_id": .nil])),
            .open(path: "/a", termID: nil)
        )
    }

    func testADocEntryNamesItsKeysUnprefixedOpenedOrRestored() throws {
        let doc: [String: MsgPackValue] = ["path": .string("/a.md"), "via": .string("cli")]
        func opened(_ extra: [String: MsgPackValue]) -> MsgPackValue {
            .map(doc.merging(extra) { $1 }.merging(["t": .string("doc_opened")]) { $1 })
        }
        func restored(_ extra: [String: MsgPackValue]) -> MsgPackValue {
            .map(["t": .string("restore"), "docs": .array([.map(doc.merging(extra) { $1 })])])
        }
        for frame in [opened, restored] {
            assertRefused(frame(["path": .nil]), .missingField("path"))
            assertRefused(frame(["via": .int(1)]), .badField("via"))
            assertRefused(frame(["repo": .int(1)]), .badField("repo"))
            assertRefused(frame(["read": .string("yes")]), .badField("read"))
        }
        XCTAssertEqual(
            try Message.decode(opened(["repo": .nil, "read": .nil, "term_id": .nil])),
            .docOpened(doc: RestoreDoc(path: "/a.md", via: "cli"))
        )
        assertRefused(.map(["t": .string("restore"), "docs": .array([.string("/a.md")])]), .badField("docs"))
    }

    func testATileNamesItsKeysUnderTiles() throws {
        func layout(_ tile: MsgPackValue) -> MsgPackValue {
            .map(["t": .string("layout"), "dock": .array([]), "tiles": .array([tile])])
        }
        assertRefused(layout(.string("term")), .badField("tiles"))
        assertRefused(layout(.map([:])), .missingField("tiles.kind"))
        assertRefused(layout(.map(["kind": .nil])), .missingField("tiles.kind"))
        assertRefused(layout(.map(["kind": .int(1)])), .badField("tiles.kind"))
        assertRefused(layout(.map(["kind": .string("term"), "x": .string("1")])), .badField("tiles.x"))
        assertRefused(layout(.map(["kind": .string("term"), "term_id": .int(1)])), .badField("tiles.term_id"))
        XCTAssertEqual(
            try Message.decode(layout(.map(["kind": .string("term"), "x": .nil, "loose": .nil]))),
            .layout(dock: [], tiles: [LayoutTile(kind: "term")], board: nil, boardID: nil)
        )
    }

    /// 2611.0024 S8: the S4 frames of the Rust suite fail on the key's name.
    func test2611_0024S8ASidebarKeyOfTheWrongTypeFailsTheFrame() {
        let vector44 = """
            83 a1 74 a6 6c 61 79 6f 75 74 a4 64 6f 63 6b 90 a5 74 69 6c 65 73 91
            84 a4 6b 69 6e 64 a3 64 6f 63 a4 70 61 74 68 a5 2f 61 2e 6d 64
            a9 73 69 64 65 62 61 72 5f 77 cb 40 72 c8 00 00 00 00 00
            ac 73 69 64 65 62 61 72 5f 6f 70 65 6e c2
            """
        let width = "cb 40 72 c8 00 00 00 00 00"
        let open = "ac 73 69 64 65 62 61 72 5f 6f 70 65 6e c2"
        let frames: [(String, MessageError)] = [
            (vector44.replacingOccurrences(of: width, with: "a4 77 69 64 65"), .badField("tiles.sidebar_w")),
            (
                vector44.replacingOccurrences(of: open, with: "ac 73 69 64 65 62 61 72 5f 6f 70 65 6e 01"),
                .badField("tiles.sidebar_open")
            ),
        ]
        for (hex, expected) in frames {
            XCTAssertThrowsError(try Message.decode(payload: hexData(hex)), hex) { error in
                XCTAssertEqual(error as? MessageError, expected)
            }
        }
    }

    func testABoardViewportNamesItsKeysUnderBoard() throws {
        func layout(_ board: MsgPackValue) -> MsgPackValue {
            .map(["t": .string("layout"), "dock": .array([]), "tiles": .array([]), "board": board])
        }
        assertRefused(layout(.array([])), .badField("board"))
        assertRefused(layout(.map(["cx": .double(0), "cy": .double(0)])), .missingField("board.zoom"))
        assertRefused(layout(.map(["zoom": .double(1), "cx": .nil, "cy": .double(0)])), .missingField("board.cx"))
        assertRefused(layout(.map(["zoom": .double(1), "cx": .double(0), "cy": .string("0")])), .badField("board.cy"))
        XCTAssertEqual(
            try Message.decode(layout(.nil)),
            .layout(dock: [], tiles: [], board: nil, boardID: nil)
        )
    }

    func testATermRecordIsMissingUnderResumeButBadUnprefixed() throws {
        func restore(_ record: MsgPackValue) -> MsgPackValue {
            .map(["t": .string("restore"), "docs": .array([]), "term_records": .map(["t1": record])])
        }
        assertRefused(restore(.string("/w")), .badField("term_records"))
        assertRefused(restore(.map(["last_cwd": .int(1)])), .badField("last_cwd"))
        assertRefused(restore(.map(["resume": .string("x")])), .badField("resume"))
        assertRefused(restore(.map(["resume": .map([:])])), .missingField("resume.cmd"))
        assertRefused(restore(.map(["resume": .map(["cmd": .nil])])), .missingField("resume.cmd"))
        assertRefused(restore(.map(["resume": .map(["cmd": .int(1)])])), .badField("cmd"))
        XCTAssertEqual(
            try Message.decode(restore(.map(["last_cwd": .nil, "resume": .nil]))),
            .restore(
                docs: [], tiles: [], board: nil, boardID: nil, liveTerms: [],
                termRecords: ["t1": TermRecord(lastCwd: nil)]
            )
        )
    }

    func testATermInfoIsMissingUnderTermsButBadUnprefixed() throws {
        func terms(_ info: MsgPackValue) -> MsgPackValue {
            .map(["t": .string("terms"), "terms": .array([info])])
        }
        let ids: [String: MsgPackValue] = ["term_id": .string("t1"), "board_id": .string("board-0")]
        assertRefused(terms(.string("t1")), .badField("terms"))
        assertRefused(terms(.map(["board_id": .string("board-0")])), .missingField("terms.term_id"))
        assertRefused(terms(.map(["term_id": .nil, "board_id": .string("board-0")])), .missingField("terms.term_id"))
        assertRefused(terms(.map(["term_id": .int(1), "board_id": .string("board-0")])), .badField("term_id"))
        assertRefused(terms(.map(["term_id": .string("t1")])), .missingField("terms.board_id"))
        assertRefused(terms(.map(["term_id": .string("t1"), "board_id": .int(0)])), .badField("board_id"))
        assertRefused(terms(.map(ids.merging(["cwd": .int(1)]) { $1 })), .badField("cwd"))
        assertRefused(terms(.map(ids.merging(["proc": .int(1)]) { $1 })), .badField("proc"))
        XCTAssertEqual(
            try Message.decode(terms(.map(ids.merging(["cwd": .nil, "proc": .nil]) { $1 }))),
            .terms([TermInfo(termID: "t1", boardID: "board-0")])
        )
    }

    func testABoardListEntryReadsAMistypedIdAsMissingAndAMistypedNameAsNone() throws {
        func list(_ entry: MsgPackValue) -> MsgPackValue {
            .map(["t": .string("board_list"), "boards": .array([entry]), "active": .string("board-0")])
        }
        assertRefused(list(.string("board-0")), .badField("boards"))
        assertRefused(list(.map([:])), .missingField("boards.board_id"))
        assertRefused(list(.map(["board_id": .int(0)])), .missingField("boards.board_id"))
        XCTAssertEqual(
            try Message.decode(list(.map(["board_id": .string("board-0"), "name": .int(1), "running": .string("2")]))),
            .boardList(boards: [BoardMeta(boardID: "board-0")], active: "board-0")
        )
    }
}
