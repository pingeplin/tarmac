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
}
