import XCTest
import TarmacKit

/// The QA driver's wire types against `tarmac_protocol::dev`. Every hex string
/// is what `dev::encode_request` / `dev::encode_reply` emits for the value named
/// above it — captured from the Rust crate, whose own tests carry no byte
/// vectors for this socket.
final class DevMessagesTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func assertParity(
        _ request: DevRequest,
        _ rustHex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = hexData(rustHex)
        XCTAssertEqual(try DevRequest.decode(payload: payload), request, file: file, line: line)
        XCTAssertEqual(hex(request.encodedPayload()), hex(payload), file: file, line: line)
    }

    private func assertParity(
        _ reply: DevReply,
        _ rustHex: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let payload = hexData(rustHex)
        XCTAssertEqual(try DevReply.decode(payload: payload), reply, file: file, line: line)
        XCTAssertEqual(hex(reply.encodedPayload()), hex(payload), file: file, line: line)
    }

    // MARK: - Requests

    func testSnapshot() {
        // DevRequest::Snapshot { until: None, timeout_ms: None }
        assertParity(.snapshot(until: nil, timeoutMs: nil), "81 a1 74 a8 73 6e 61 70 73 68 6f 74")
        // DevRequest::Snapshot { until: Some("cards[t-1].term.cols != 80"), timeout_ms: Some(1500) }
        assertParity(
            .snapshot(until: "cards[t-1].term.cols != 80", timeoutMs: 1500),
            """
            83 a1 74 a8 73 6e 61 70 73 68 6f 74 a5 75 6e 74 69 6c ba 63 61 72 64 73
            5b 74 2d 31 5d 2e 74 65 72 6d 2e 63 6f 6c 73 20 21 3d 20 38 30 aa 74 69
            6d 65 6f 75 74 5f 6d 73 cd 05 dc
            """
        )
        // DevRequest::Snapshot { until: None, timeout_ms: Some(5000) } — what a
        // bare `tarmac dev snapshot` sends.
        assertParity(
            .snapshot(until: nil, timeoutMs: 5000),
            """
            82 a1 74 a8 73 6e 61 70 73 68 6f 74 aa 74 69 6d 65 6f 75 74 5f 6d 73 cd
            13 88
            """
        )
    }

    func testBoardVerbs() {
        // DevRequest::Zoom { z: 0.5 }
        assertParity(.zoom(z: 0.5), "82 a1 74 a4 7a 6f 6f 6d a1 7a cb 3f e0 00 00 00 00 00 00")
        // DevRequest::Focus { card: Some("t-1") }
        assertParity(.focus(card: "t-1"), "82 a1 74 a5 66 6f 63 75 73 a4 63 61 72 64 a3 74 2d 31")
        // DevRequest::Focus { card: None } — the board background; no sentinel.
        assertParity(.focus(card: nil), "81 a1 74 a5 66 6f 63 75 73")
        // DevRequest::Resize { card: "t-1", w: 800.0, h: 600.0 }
        assertParity(
            .resize(card: "t-1", w: 800, h: 600),
            """
            84 a1 74 a6 72 65 73 69 7a 65 a4 63 61 72 64 a3 74 2d 31 a1 77 cb 40 89
            00 00 00 00 00 00 a1 68 cb 40 82 c0 00 00 00 00 00
            """
        )
    }

    func testCardInputVerbs() {
        // DevRequest::Type { card: "t-1", text: "a\nb" }
        assertParity(
            .type(card: "t-1", text: "a\nb"),
            """
            83 a1 74 a4 74 79 70 65 a4 63 61 72 64 a3 74 2d 31 a4 74 65 78 74 a3 61
            0a 62
            """
        )
        // DevRequest::Key { card: "t-1", combo: "ctrl+c" }
        assertParity(
            .key(card: "t-1", combo: "ctrl+c"),
            """
            83 a1 74 a3 6b 65 79 a4 63 61 72 64 a3 74 2d 31 a5 63 6f 6d 62 6f a6 63
            74 72 6c 2b 63
            """
        )
    }

    /// S2 (2609.0018): every `press` shape, and absent flags are absent keys,
    /// not nils.
    func testPress() {
        // DevRequest::Press { combo: "cmd+q", hold_ms: None, age_ms: None, busy_ms: None }
        assertParity(
            .press(combo: "cmd+q", holdMs: nil, ageMs: nil, busyMs: nil),
            "82 a1 74 a5 70 72 65 73 73 a5 63 6f 6d 62 6f a5 63 6d 64 2b 71"
        )
        // DevRequest::Press { combo: "cmd+q", hold_ms: Some(1000), .. }
        assertParity(
            .press(combo: "cmd+q", holdMs: 1000, ageMs: nil, busyMs: nil),
            """
            83 a1 74 a5 70 72 65 73 73 a5 63 6f 6d 62 6f a5 63 6d 64 2b 71 a7 68 6f
            6c 64 5f 6d 73 cd 03 e8
            """
        )
        // DevRequest::Press { combo: "alt+cmd+q", hold_ms: Some(10000), age_ms: Some(0), busy_ms: None }
        assertParity(
            .press(combo: "alt+cmd+q", holdMs: 10000, ageMs: 0, busyMs: nil),
            """
            84 a1 74 a5 70 72 65 73 73 a5 63 6f 6d 62 6f a9 61 6c 74 2b 63 6d 64 2b
            71 a7 68 6f 6c 64 5f 6d 73 cd 27 10 a6 61 67 65 5f 6d 73 00
            """
        )
        // DevRequest::Press { combo: "cmd+q", hold_ms: None, age_ms: None, busy_ms: Some(1800) }
        assertParity(
            .press(combo: "cmd+q", holdMs: nil, ageMs: nil, busyMs: 1800),
            """
            83 a1 74 a5 70 72 65 73 73 a5 63 6f 6d 62 6f a5 63 6d 64 2b 71 a7 62 75
            73 79 5f 6d 73 cd 07 08
            """
        )
    }

    /// S47: a verb this build does not know decodes to a value, so the app can
    /// answer "unsupported" instead of dropping the frame.
    func testUnknownVerbDecodesToUnknown() throws {
        // What Rust writes for DevRequest::Unknown: {t:"unknown"}.
        XCTAssertEqual(
            try DevRequest.decode(payload: hexData("81 a1 74 a7 75 6e 6b 6e 6f 77 6e")),
            .unknown(type: "unknown")
        )
        // {t:"teleport", card:"x"} — a newer CLI's verb, payload and all.
        XCTAssertEqual(
            try DevRequest.decode(payload: hexData("82 a1 74 a8 74 65 6c 65 70 6f 72 74 a4 63 61 72 64 a1 78")),
            .unknown(type: "teleport")
        )
    }

    /// S47 / S31: additive-only — an unknown key on a known request is ignored.
    func testUnknownKeysAreIgnored() throws {
        XCTAssertEqual(
            try DevRequest.decode(.map(["t": .string("zoom"), "z": .double(0.5), "anchor": .string("pointer")])),
            .zoom(z: 0.5)
        )
        XCTAssertEqual(
            try DevRequest.decode(.map([
                "t": .string("press"), "combo": .string("cmd+q"), "hold_ms": .int(1), "pressure": .int(5),
            ])),
            .press(combo: "cmd+q", holdMs: 1, ageMs: nil, busyMs: nil)
        )
    }

    func testKeyOrderAndExplicitNilAreAccepted() throws {
        // {t:"focus", card:nil}
        XCTAssertEqual(
            try DevRequest.decode(payload: hexData("82 a1 74 a5 66 6f 63 75 73 a4 63 61 72 64 c0")),
            .focus(card: nil)
        )
        // {z:1, t:"zoom"} — tag last, and an integer where the float goes; the
        // Rust decoder reads both as Zoom { z: 1.0 }.
        XCTAssertEqual(try DevRequest.decode(payload: hexData("82 a1 7a 01 a1 74 a4 7a 6f 6f 6d")), .zoom(z: 1.0))
    }

    /// The wire type is `u32`; a wider or negative count is a malformed frame,
    /// not a budget to add slack to.
    func testAMillisecondCountOutsideTheWireTypeIsMalformed() {
        let cases: [(String, String, Int64)] = [
            ("snapshot", "timeout_ms", .max), ("snapshot", "timeout_ms", -1),
            ("press", "hold_ms", Int64(UInt32.max) + 1), ("press", "age_ms", -1), ("press", "busy_ms", .max),
        ]
        for (t, key, value) in cases {
            let request: MsgPackValue = .map(["t": .string(t), "combo": .string("cmd+q"), key: .int(value)])
            XCTAssertThrowsError(try DevRequest.decode(request), "\(key)=\(value)") { error in
                XCTAssertEqual(error as? MessageError, .badField(key))
            }
        }
        XCTAssertEqual(
            try DevRequest.decode(.map(["t": .string("snapshot"), "timeout_ms": .int(Int64(UInt32.max))])),
            .snapshot(until: nil, timeoutMs: Int(UInt32.max))
        )
    }

    func testMalformedRequestsThrow() {
        XCTAssertThrowsError(try DevRequest.decode(.map(["z": .double(0.5)]))) { error in
            XCTAssertEqual(error as? MessageError, .missingField("t"))
        }
        XCTAssertThrowsError(try DevRequest.decode(.map(["t": .string("zoom")]))) { error in
            XCTAssertEqual(error as? MessageError, .missingField("z"))
        }
        XCTAssertThrowsError(try DevRequest.decode(.map(["t": .string("type"), "card": .int(1), "text": .string("x")]))) { error in
            XCTAssertEqual(error as? MessageError, .badField("card"))
        }
        XCTAssertThrowsError(try DevRequest.decode(.array([]))) { error in
            XCTAssertEqual(error as? MessageError, .notAMap)
        }
    }

    /// S23 (2609.0018): the caller's own budget, where the verb has one —
    /// `snapshot` its `--timeout`, `press` its `--busy`. Both ends of the socket
    /// size their wait from it.
    func testTimeoutIsTheVerbsOwnBudget() {
        XCTAssertEqual(DevRequest.snapshot(until: nil, timeoutMs: 1500).timeoutMs, 1500)
        XCTAssertNil(DevRequest.snapshot(until: "x", timeoutMs: nil).timeoutMs)
        XCTAssertEqual(DevRequest.press(combo: "cmd+q", holdMs: 9, ageMs: 8, busyMs: 1000).timeoutMs, 1000)
        XCTAssertNil(DevRequest.press(combo: "cmd+q", holdMs: 9, ageMs: 8, busyMs: nil).timeoutMs)
        XCTAssertNil(DevRequest.zoom(z: 1).timeoutMs)
        XCTAssertNil(DevRequest.key(card: "t-1", combo: "ctrl+c").timeoutMs)
    }

    func testPressRangesMatchTheProtocolConstants() {
        XCTAssertEqual(DevRequest.holdMsMax, 10_000)
        XCTAssertEqual(DevRequest.ageMsMax, 60_000)
        XCTAssertEqual(DevRequest.busyMsMax, 1_800)
    }

    // MARK: - Replies

    /// S48: `body` is opaque — it survives byte for byte, JSON or not.
    func testReply() {
        // DevReply { ok: true, body: "{\"v\":1}" }
        assertParity(DevReply(ok: true, body: "{\"v\":1}"), "82 a2 6f 6b c3 a4 62 6f 64 79 a7 7b 22 76 22 3a 31 7d")
        // DevReply { ok: false, body: "two\nlines" }
        assertParity(
            DevReply(ok: false, body: "two\nlines"),
            "82 a2 6f 6b c2 a4 62 6f 64 79 a9 74 77 6f 0a 6c 69 6e 65 73"
        )
        // DevReply { ok: true, body: "" }
        assertParity(DevReply(ok: true, body: ""), "82 a2 6f 6b c3 a4 62 6f 64 79 a0")
    }

    func testReplyDecodingRules() throws {
        // {body:"x", ok:false, extra:1} — any key order, unknown keys ignored.
        XCTAssertEqual(
            try DevReply.decode(payload: hexData("83 a4 62 6f 64 79 a1 78 a2 6f 6b c2 a5 65 78 74 72 61 01")),
            DevReply(ok: false, body: "x")
        )
        // {ok:true} — `body` is required.
        XCTAssertThrowsError(try DevReply.decode(payload: hexData("81 a2 6f 6b c3"))) { error in
            XCTAssertEqual(error as? MessageError, .missingField("body"))
        }
    }
}
