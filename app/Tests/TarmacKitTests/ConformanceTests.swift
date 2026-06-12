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

/// The four mandatory conformance vectors from docs/protocol.md.
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
        let message = Message.restore(docs: [
            RestoreDoc(path: "/tmp/a.md", via: "cli", lastChangedMs: 1_765_432_100_123),
            RestoreDoc(path: "/tmp/b.md", via: "user", lastChangedMs: nil),
        ])
        XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
    }

    func testAllMessagesRoundTrip() throws {
        let messages: [Message] = [
            .hello(role: "cli", v: 1),
            .helloOK(v: 1),
            .ack,
            .err(msg: "nope"),
            .open(path: "/abs/x.md"),
            .restore(docs: []),
            .spawnTerm(termID: "u-1", cols: 191, rows: 49, cwd: "/Users/x", cmd: ["/bin/echo", "hi"]),
            .input(termID: "u-1", bytes: Data([0x03])),
            .resize(termID: "u-1", cols: 80, rows: 24),
            .output(termID: "u-1", bytes: Data(repeating: 0xab, count: 70_000)),
            .exit(termID: "u-1", code: -1),
            .exit(termID: "u-1", code: nil),
            .docOpened(path: "/abs/x.md", via: "user"),
            .fileEvent(path: "/abs/x.md", mtimeMs: 1_765_432_100_123),
        ]
        for message in messages {
            XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
        }
    }
}
