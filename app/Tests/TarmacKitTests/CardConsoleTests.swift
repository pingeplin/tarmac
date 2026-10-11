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

    /// #213: the host page says that the card's document is on screen, and
    /// which load of the frame it is of.
    func testAcceptsTheShownPayload() {
        XCTAssertEqual(parse(["tarmac": "shown", "load": 3]), .shown(load: 3))
    }

    func testRejectsAShownPayloadThatNamesNoLoad() {
        XCTAssertNil(parse(["tarmac": "shown"]))
        XCTAssertNil(parse(["tarmac": "shown", "load": "3"]))
        XCTAssertNil(parse(["tarmac": "shown", "load": 1.5]))
    }

    /// The document's own first word stops at the host page.
    func testRejectsAStartedPayload() {
        XCTAssertNil(parse(["tarmac": "started"]))
    }

    // MARK: - scrolled payload (2610.0003 S10, S34)

    func test2610S10AcceptsAScrolledPayload() {
        XCTAssertEqual(
            parse(["tarmac": "scrolled", "offset": 30, "visible": 100, "total": 400]),
            ScrollMetrics(offset: 30, visible: 100, total: 400).map(CardConsole.Message.scrolled)
        )
        XCTAssertNotNil(parse(["tarmac": "scrolled", "offset": 30, "visible": 100, "total": 400]))
    }

    func test2610S34RejectsAScrolledPayloadThatDescribesNoScroller() {
        XCTAssertNil(parse(["tarmac": "scrolled", "offset": 30, "visible": 0, "total": 400]))
        XCTAssertNil(parse(["tarmac": "scrolled", "visible": 100, "total": 400]))
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

    // MARK: - line cap

    func testALineIsCappedAtAThousandCharacters() {
        XCTAssertEqual(CardConsole.lineCap, 1000)
    }

    /// A card is not trusted with how much it logs: one entry may be megabytes.
    /// What is kept is the head of its line and how much was cut.
    func testAnEntryLongerThanTheCapKeepsItsHeadAndSaysHowMuchWasCut() {
        var buffer = CardConsole.Buffer()
        buffer.push(CardConsole.Entry(level: .warn, args: [.string(String(repeating: "x", count: 1500)), 7]))

        let kept = buffer.entries[0]
        XCTAssertEqual(kept.level, .warn)
        XCTAssertEqual(
            CardConsole.formatArgs(kept.args),
            String(repeating: "x", count: 1000) + "… (+502 more)"
        )
    }

    func testAnEntryAtTheCapIsKeptAsItCame() {
        var buffer = CardConsole.Buffer()
        let atCap = CardConsole.Entry(level: .log, args: [.string(String(repeating: "x", count: 998)), 7])
        buffer.push(atCap)
        XCTAssertEqual(buffer.entries, [atCap])
    }

    func testAShortEntryKeepsItsArgsUntouched() {
        var buffer = CardConsole.Buffer()
        let short = CardConsole.Entry(level: .log, args: ["a", ["k": 1], [1, 2]])
        buffer.push(short)
        XCTAssertEqual(buffer.entries, [short])
    }

    /// The cut never splits a character.
    func testTheCutFallsBetweenCharacters() {
        var buffer = CardConsole.Buffer()
        buffer.push(CardConsole.Entry(level: .log, args: [.string(String(repeating: "👩‍👩‍👧", count: 1001))]))
        XCTAssertEqual(
            CardConsole.formatArgs(buffer.entries[0].args),
            String(repeating: "👩‍👩‍👧", count: 1000) + "… (+1 more)"
        )
    }

    // MARK: - what the host page cut

    /// A megabyte entry costs the app's main thread as it crosses from the
    /// page, so the host page cuts it first and says how much it cut.
    func testAConsolePayloadSaysHowMuchThePageCut() {
        XCTAssertEqual(
            parse(["tarmac": "console", "level": "log", "args": ["head"], "dropped": 4096] as [String: Any]),
            .console(CardConsole.Entry(level: .log, args: ["head"], dropped: 4096))
        )
    }

    func testAPayloadThatDoesNotSayHasNothingCut() {
        for dropped in [nil, -3, 1.5, "12", NSNull()] as [Any?] {
            var payload: [String: Any] = ["tarmac": "console", "level": "log", "args": ["a"]]
            payload["dropped"] = dropped
            XCTAssertEqual(parse(payload), .console(CardConsole.Entry(level: .log, args: ["a"])), "\(String(describing: dropped))")
        }
    }

    func testWhatThePageCutIsCountedInTheMark() {
        var buffer = CardConsole.Buffer()
        buffer.push(CardConsole.Entry(level: .error, args: [.string(String(repeating: "x", count: 1000))], dropped: 500))

        XCTAssertEqual(
            buffer.entries,
            [CardConsole.Entry(level: .error, args: [.string(String(repeating: "x", count: 1000) + "… (+500 more)")])]
        )
    }

    func testAShortLineThePageCutStillSaysSo() {
        var buffer = CardConsole.Buffer()
        buffer.push(CardConsole.Entry(level: .log, args: ["abc", 7], dropped: 5))
        XCTAssertEqual(CardConsole.formatArgs(buffer.entries[0].args), "abc 7… (+5 more)")
    }

    func testBothCutsAddUp() {
        var buffer = CardConsole.Buffer()
        buffer.push(CardConsole.Entry(level: .log, args: [.string(String(repeating: "x", count: 1200))], dropped: 300))
        XCTAssertEqual(
            CardConsole.formatArgs(buffer.entries[0].args),
            String(repeating: "x", count: 1000) + "… (+500 more)"
        )
    }

    // MARK: - refresh

    /// A flooding card costs the app at most ten console updates a second.
    func testTheConsoleIsRefreshedAtMostTenTimesASecond() {
        XCTAssertEqual(CardConsole.refreshInterval, 0.1)
    }

    // MARK: - formatArgs

    func testJoinsPrimitivesWithSpaces() {
        XCTAssertEqual(CardConsole.formatArgs(["tick", 42, true]), "tick 42 true")
    }

    func testStringifiesObjectsAndArraysInsteadOfAnOpaquePlaceholder() {
        XCTAssertEqual(CardConsole.formatArgs([["a": 1], [1, 2]]), #"{"a":1} [1,2]"#)
    }

    func testRendersNullLiterally() {
        XCTAssertEqual(CardConsole.formatArgs([.null]), "null")
    }

    func testNoArgsFormatAsAnEmptyLine() {
        XCTAssertEqual(CardConsole.formatArgs([]), "")
    }

    func testANegativeCapBehavesAsZero() {
        var buffer = CardConsole.Buffer(cap: -5)
        XCTAssertEqual(buffer.cap, 0)
        buffer.push(CardConsole.Entry(level: .log, args: []))
        XCTAssertEqual(buffer.entries, [])
    }

    // MARK: - badge

    func testTheBadgeCountsTheBufferedEntries() {
        XCTAssertEqual(CardConsole.badgeLabel(count: 1), "⌥ 1")
        XCTAssertEqual(CardConsole.badgeLabel(count: 500), "⌥ 500")
    }

    func testAnEmptyBufferHasNoBadge() {
        XCTAssertNil(CardConsole.badgeLabel(count: 0))
    }
}
