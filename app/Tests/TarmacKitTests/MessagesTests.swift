import XCTest
@testable import TarmacKit

/// What `Message` refuses in a frame it knows (spec 2611.0003 S41).
final class MessagesTests: XCTestCase {
    private func decoded(_ fields: [String: MsgPackValue]) throws -> Message {
        try Message.decode(payload: MsgPack.encode(.map(fields)))
    }

    func testS41ADocEventDecodesWithItsPathAndData() throws {
        XCTAssertEqual(
            try decoded(["t": .string("doc_event"), "path": .string("/a/dash.html"), "data": .string("[1]")]),
            .docEvent(path: "/a/dash.html", data: "[1]")
        )
    }

    func testS41ADocEventWithNoDataIsRefused() {
        for fields: [String: MsgPackValue] in [
            ["t": .string("doc_event"), "path": .string("/a/dash.html")],
            ["t": .string("doc_event"), "path": .string("/a/dash.html"), "data": .nil],
        ] {
            XCTAssertThrowsError(try decoded(fields)) { error in
                XCTAssertEqual(error as? MessageError, .missingField("data"))
            }
        }
    }

    func testS41ADocEventWhoseDataIsNoStringIsRefused() {
        for data: MsgPackValue in [.int(1), .binary(Data("[1]".utf8)), .array([.string("[1]")])] {
            XCTAssertThrowsError(
                try decoded(["t": .string("doc_event"), "path": .string("/a/dash.html"), "data": data])
            ) { error in
                XCTAssertEqual(error as? MessageError, .badField("data"), "\(data)")
            }
        }
    }
}
