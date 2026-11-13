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
}
