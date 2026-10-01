import XCTest
@testable import TarmacKit

/// Host side of the HTML-card console relay: validating the shim's postMessage
/// payloads and the per-card ring buffer. Two specs share these cases —
/// 2607.0004 (payload validation S4/S17, ring buffer S5) and 2607.0006 (ready
/// payload S4/S14, forged host→shim rejection S16) — so every id is qualified
/// with its spec number.
final class CardConsoleTests: XCTestCase {
    private typealias Message = CardConsole.Message
    private func parse(_ body: Any) -> Message? { CardConsole.parse(body) }

    // MARK: - parse (2607.0004 S4)

    func testAcceptsAWellFormedConsolePayload() {
        XCTAssertEqual(
            parse(["tarmac": "console", "level": "warn", "args": ["a", 1] as [Any]]),
            .console(CardConsole.Entry(level: .warn, args: ["a", 1]))
        )
    }

    func testAcceptsEveryConsoleLevel() {
        for (name, level) in [("log", CardConsole.Level.log), ("info", .info), ("warn", .warn), ("error", .error)] {
            XCTAssertEqual(
                parse(["tarmac": "console", "level": name, "args": [] as [Any]]),
                .console(CardConsole.Entry(level: level, args: [])),
                name
            )
        }
    }

    func testAcceptsTheEscapePayload() {
        XCTAssertEqual(parse(["tarmac": "escape"]), .escape)
    }

    // MARK: - ready payload (2607.0006 S4)

    func testAcceptsAReadyPayloadWithStringMeta() {
        XCTAssertEqual(parse(["tarmac": "ready", "meta": "magnify"]), .ready(meta: "magnify"))
    }

    func testAcceptsAReadyPayloadWithNullMeta() {
        XCTAssertEqual(parse(["tarmac": "ready", "meta": NSNull()]), .ready(meta: nil))
    }

    /// The probe field was removed with the capability probe (#94). It gets no
    /// special treatment: a card that forges one is handled exactly like a card
    /// forging any other unknown key — ignored, not rejected.
    func testIgnoresAStrayProbeKeyExactlyAsItIgnoresAnyOtherUnknownKey() {
        let bare = Message.ready(meta: "magnify")
        let probe: [String: Any] = ["base": 400, "zoomed": 200]
        XCTAssertEqual(parse(["tarmac": "ready", "meta": "magnify", "probe": probe]), bare)
        XCTAssertEqual(parse(["tarmac": "ready", "meta": "magnify", "probe": NSNull()]), bare)
        XCTAssertEqual(parse(["tarmac": "ready", "meta": "magnify", "probe": "nonsense"]), bare)
        XCTAssertEqual(parse(["tarmac": "ready", "meta": "magnify", "somethingElse": 1]), bare)
    }

    // MARK: - rejects junk (2607.0004 S17)

    func testRejectsNonTarmacAndMalformedPayloads() {
        XCTAssertNil(parse(NSNull()))
        XCTAssertNil(parse("hello"))
        XCTAssertNil(parse(42))
        XCTAssertNil(parse([Any]()))
        XCTAssertNil(parse([String: Any]()))
        XCTAssertNil(parse(["tarmac": "bogus"]))
        XCTAssertNil(parse(["tarmac": 3]))
        XCTAssertNil(parse(["level": "log", "args": [] as [Any]]))
    }

    func testRejectsConsolePayloadsWithAnUnknownLevelOrMissingArgs() {
        XCTAssertNil(parse(["tarmac": "console", "level": "debug", "args": [] as [Any]]))
        XCTAssertNil(parse(["tarmac": "console", "level": "log"]))
        XCTAssertNil(parse(["tarmac": "console", "level": "log", "args": "x"]))
        XCTAssertNil(parse(["tarmac": "console", "level": 3, "args": [] as [Any]]))
    }

    /// Standing guard: `cull` is host→shim only and must never enter the shim→host
    /// union, or a card could forge one at the host (2609.0002 S4).
    func testRejectsACullPayload() {
        XCTAssertNil(parse(["tarmac": "cull", "culled": true]))
        XCTAssertNil(parse(["tarmac": "cull", "culled": false]))
    }

    func testRejectsAConsolePayloadWhoseArgsCarryAValueJSONCannotHold() {
        XCTAssertNil(parse(["tarmac": "console", "level": "log", "args": [Date()] as [Any]]))
    }

    /// The card is an untrusted page and can post a payload of any depth.
    func testRejectsAConsolePayloadWhoseArgsNestPastTheLimitWithoutOverflowingTheStack() {
        var deep: Any = 1
        for _ in 0..<10_000 { deep = [deep] as [Any] }
        XCTAssertNil(parse(["tarmac": "console", "level": "log", "args": [deep] as [Any]]))
    }

    // MARK: - malformed ready (2607.0006 S14)

    func testRejectsAReadyPayloadWithNonStringNonNullMeta() {
        XCTAssertNil(parse(["tarmac": "ready", "meta": 1]))
        XCTAssertNil(parse(["tarmac": "ready", "meta": [String: Any]()]))
        XCTAssertNil(parse(["tarmac": "ready", "meta": true]))
    }

    func testRejectsABareReadyPayload() {
        XCTAssertNil(parse(["tarmac": "ready"]))
    }

    /// Absent is neither a string nor null (2607.0006 S14, guards 2607.0006 S8).
    func testRejectsAReadyPayloadWithTheMetaKeyAbsent() {
        let probe: [String: Any] = ["base": 400, "zoomed": 200]
        XCTAssertNil(parse(["tarmac": "ready", "probe": probe]))
    }

    func testStillParsesPreviouslyValidConsoleAndEscapePayloadsUnchanged() {
        XCTAssertEqual(parse(["tarmac": "escape"]), .escape)
        XCTAssertEqual(
            parse(["tarmac": "console", "level": "warn", "args": ["a", 1] as [Any]]),
            .console(CardConsole.Entry(level: .warn, args: ["a", 1]))
        )
    }

    // MARK: - forged host→shim (2607.0006 S16)

    func testRejectsAnInboundZoomPayloadWhichIsNotAHostMessageKind() {
        XCTAssertNil(parse(["tarmac": "zoom", "z": 40]))
    }

    // MARK: - ring buffer (2607.0004 S5)

    private func entry(_ n: Double) -> CardConsole.Entry {
        CardConsole.Entry(level: .log, args: [.number(n)])
    }

    private func firstArgs(_ buffer: CardConsole.Buffer) -> [JSONValue] {
        buffer.entries.compactMap(\.args.first)
    }

    func testAppendsInOrderBelowTheCap() {
        var buffer = CardConsole.Buffer()
        buffer.push(entry(1))
        buffer.push(entry(2))
        XCTAssertEqual(firstArgs(buffer), [1, 2])
    }

    func testDropsTheOldestBeyondTheCapAndPreservesOrder() {
        var buffer = CardConsole.Buffer()
        for i in 0..<CardConsole.bufferCap { buffer.push(entry(Double(i))) }
        XCTAssertEqual(buffer.entries.count, CardConsole.bufferCap)

        buffer.push(entry(Double(CardConsole.bufferCap)))
        XCTAssertEqual(buffer.entries.count, CardConsole.bufferCap)
        XCTAssertEqual(buffer.entries.first?.args.first, 1, "the oldest (0) was dropped")
        XCTAssertEqual(buffer.entries.last?.args.first, .number(Double(CardConsole.bufferCap)))
    }

    func testHonorsAnExplicitCap() {
        var buffer = CardConsole.Buffer(cap: 3)
        for i in 0..<5 { buffer.push(entry(Double(i))) }
        XCTAssertEqual(firstArgs(buffer), [2, 3, 4])
    }

    func testTheDefaultCapIs500() {
        XCTAssertEqual(CardConsole.bufferCap, 500)
        XCTAssertEqual(CardConsole.Buffer().cap, 500)
    }

    // MARK: - formatArgs

    func testJoinsPrimitivesWithSpaces() {
        XCTAssertEqual(CardConsole.formatArgs(["tick", 42, true]), "tick 42 true")
    }

    func testStringifiesObjectsAndArraysInsteadOfAnOpaquePlaceholder() {
        XCTAssertEqual(CardConsole.formatArgs([["a": 1], [1, 2]]), #"{"a":1} [1,2]"#)
    }

    func testRendersNullLiterally() {
        XCTAssertEqual(CardConsole.formatArgs([nil]), "null")
    }

    func testNoArgsFormatAsAnEmptyLine() {
        XCTAssertEqual(CardConsole.formatArgs([]), "")
    }
}
