import XCTest
@testable import TarmacKit

/// The hold/release rule ported from `desktop/src-tauri/src/bridge.rs`, with its
/// tests. Names follow the Rust ones.
final class ScrollbackGateTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// The bytes of an `.append`, run together.
    private func appended(_ release: ScrollbackGate.Release?) -> Data? {
        guard case .append(let chunks) = release else { return nil }
        return chunks.reduce(into: Data()) { $0.append($1) }
    }

    /// A gate holding `term`'s output behind an outstanding request.
    private func awaitingGate(_ term: String = "t1", capBytes: Int = ScrollbackGate.bufferCapBytes)
        -> (gate: ScrollbackGate, generation: UInt64)
    {
        var gate = ScrollbackGate(capBytes: capBytes)
        let generation = gate.attach(term)
        return (gate, generation)
    }

    // MARK: - held bytes

    func testHeldChunksAreReleasedInOrder() {
        var (gate, generation) = awaitingGate()
        XCTAssertNil(gate.output("t1", bytes("hello ")))
        XCTAssertNil(gate.output("t1", bytes("world")))

        XCTAssertEqual(gate.expire("t1", generation: generation), .append([bytes("hello "), bytes("world")]))
        XCTAssertEqual(gate.heldBytes("t1"), 0)
    }

    func testHeldBytesAreIndependentPerTerminal() {
        var gate = ScrollbackGate()
        let first = gate.attach("t1")
        let second = gate.attach("t2")
        XCTAssertNil(gate.output("t1", bytes("for t1")))
        XCTAssertNil(gate.output("t2", bytes("for t2")))

        XCTAssertEqual(gate.expire("t1", generation: first), .append([bytes("for t1")]))
        XCTAssertEqual(gate.expire("t2", generation: second), .append([bytes("for t2")]))
    }

    func testCapEvictsTheOldestChunks() {
        var (gate, generation) = awaitingGate(capBytes: 10)
        _ = gate.output("t1", bytes("AAAAA"))
        _ = gate.output("t1", bytes("BBBBB"))
        _ = gate.output("t1", bytes("CCCCC"))

        XCTAssertEqual(appended(gate.expire("t1", generation: generation)), bytes("BBBBBCCCCC"))
    }

    func testOneChunkCanEvictSeveral() {
        var (gate, generation) = awaitingGate(capBytes: 10)
        _ = gate.output("t1", bytes("AAAA"))
        _ = gate.output("t1", bytes("BBBB"))
        _ = gate.output("t1", bytes("CCCCCCCC"))

        XCTAssertEqual(gate.heldBytes("t1"), 8)
        XCTAssertEqual(gate.expire("t1", generation: generation), .append([bytes("CCCCCCCC")]))
    }

    func testAnOversizedChunkKeepsOnlyItsTail() {
        var (gate, generation) = awaitingGate(capBytes: 4)
        _ = gate.output("t1", bytes("ABCDEFGH"))

        XCTAssertEqual(appended(gate.expire("t1", generation: generation)), bytes("EFGH"))
    }

    func testAnOversizedChunkEvictsEverythingHeldBeforeIt() {
        var (gate, generation) = awaitingGate(capBytes: 4)
        _ = gate.output("t1", bytes("xy"))
        _ = gate.output("t1", bytes("ABCDEFGH"))

        XCTAssertEqual(appended(gate.expire("t1", generation: generation)), bytes("EFGH"))
    }

    func testEmptyOutputIsNotHeld() {
        var (gate, generation) = awaitingGate()
        XCTAssertNil(gate.output("t1", Data()))

        XCTAssertEqual(gate.heldBytes("t1"), 0)
        XCTAssertEqual(gate.expire("t1", generation: generation), .append([]))
    }

    func testTheDefaultCapIs256KiBAndTheDeadline2000Ms() {
        XCTAssertEqual(ScrollbackGate.bufferCapBytes, 262_144)
        XCTAssertEqual(ScrollbackGate.awaitTimeoutMs, 2000)

        var (gate, _) = awaitingGate()
        _ = gate.output("t1", Data(count: 200_000))
        _ = gate.output("t1", Data(count: 62_144))
        XCTAssertEqual(gate.heldBytes("t1"), 262_144)
        _ = gate.output("t1", Data(count: 1))
        XCTAssertEqual(gate.heldBytes("t1"), 62_145)
    }

    // MARK: - attach / reply

    func testAttachMarksTheTerminalAwaiting() {
        var gate = ScrollbackGate()
        XCTAssertFalse(gate.isAwaiting("t1"))

        _ = gate.attach("t1")

        XCTAssertTrue(gate.isAwaiting("t1"))
    }

    /// The reply is the single source: bytes held while awaiting are discarded,
    /// because the daemon's ring already contains them.
    func testScrollbackReplyDiscardsTheHeldBytesAndDeliversOnlyTheRing() {
        var (gate, _) = awaitingGate()
        _ = gate.output("t1", bytes("live"))

        XCTAssertEqual(gate.scrollback("t1", bytes("history")), .replace(bytes("history")))

        XCTAssertFalse(gate.isAwaiting("t1"))
        XCTAssertEqual(gate.heldBytes("t1"), 0)
    }

    func testOutputIsHeldWhileAwaitingAndShownAfter() {
        var (gate, _) = awaitingGate()
        XCTAssertNil(gate.output("t1", bytes("held")), "an awaiting terminal must not show output")

        XCTAssertNotNil(gate.scrollback("t1", Data()), "an empty ring is still the answer")
        XCTAssertEqual(gate.output("t1", bytes("live")), .append([bytes("live")]))
    }

    /// The daemon answers for a terminal it no longer runs with an empty ring.
    /// A card held open for that terminal keeps the screen it died with.
    func testAnEmptyRingReplacesNothing() {
        var (gate, _) = awaitingGate()
        _ = gate.output("t1", bytes("held"))

        XCTAssertEqual(gate.scrollback("t1", Data()), .append([]))

        XCTAssertFalse(gate.isAwaiting("t1"))
        XCTAssertEqual(gate.heldBytes("t1"), 0)
    }

    func testOutputForATerminalThatNeverAttachedIsShown() {
        var gate = ScrollbackGate()
        XCTAssertEqual(gate.output("t1", bytes("live")), .append([bytes("live")]))
    }

    /// A card removed mid-request leaves nothing behind, and its late reply is
    /// dropped.
    func testForgetClearsTheAwaitingMarkAndTheHeldBytes() {
        var (gate, _) = awaitingGate()
        _ = gate.output("t1", bytes("held"))

        gate.forget("t1")

        XCTAssertFalse(gate.isAwaiting("t1"))
        XCTAssertEqual(gate.heldBytes("t1"), 0)
        XCTAssertNil(gate.scrollback("t1", bytes("history")), "a reply after forget must be dropped")
        XCTAssertEqual(gate.heldBytes("t1"), 0)
    }

    func testScrollbackForANonAwaitingTerminalIsDropped() {
        var (gate, _) = awaitingGate()
        _ = gate.scrollback("t1", Data())

        XCTAssertNil(gate.scrollback("t1", bytes("duplicate")), "a duplicate reply must not be shown")
        XCTAssertNil(gate.scrollback("never-attached", bytes("orphan")))
    }

    func testAReplyAnswersOnlyItsOwnTerminal() {
        var (gate, _) = awaitingGate("t1")

        XCTAssertNil(gate.scrollback("t2", bytes("history")))
        XCTAssertTrue(gate.isAwaiting("t1"))
    }

    // MARK: - deadline

    /// A daemon that never answers must not blank the card: at the deadline the
    /// held bytes are released once, as live output after whatever the card
    /// shows, and a reply arriving later is dropped.
    func testAnUnansweredRequestExpiresAndReleasesTheHeldBytes() {
        var (gate, generation) = awaitingGate()
        XCTAssertNil(gate.output("t1", bytes("live")))

        XCTAssertEqual(gate.expire("t1", generation: generation), .append([bytes("live")]))

        XCTAssertFalse(gate.isAwaiting("t1"))
        XCTAssertNil(gate.scrollback("t1", bytes("history")), "a reply after the deadline is dropped")
        XCTAssertNil(gate.expire("t1", generation: generation), "a deadline fires once")
    }

    /// Nothing was held, so nothing reaches the card and what it shows stays.
    func testADeadlineWithNothingHeldReleasesNothing() {
        var (gate, generation) = awaitingGate()

        XCTAssertEqual(gate.expire("t1", generation: generation), .append([]))
    }

    /// A card that unmounted and remounted inside the window must not lose its
    /// history to the first mount's deadline.
    func testAStaleDeadlineLeavesTheRemountedCardAwaiting() {
        var gate = ScrollbackGate()
        let stale = gate.attach("t1")
        gate.forget("t1")
        let current = gate.attach("t1")
        _ = gate.output("t1", bytes("live"))

        XCTAssertNotEqual(stale, current, "each attach gets its own generation")
        XCTAssertNil(gate.expire("t1", generation: stale), "a stale deadline must not release the remount")
        XCTAssertTrue(gate.isAwaiting("t1"))

        XCTAssertEqual(gate.scrollback("t1", bytes("history")), .replace(bytes("history")))
    }

    func testAReattachSupersedesTheEarlierDeadline() {
        var gate = ScrollbackGate()
        let first = gate.attach("t1")
        let second = gate.attach("t1")

        XCTAssertNil(gate.expire("t1", generation: first))
        XCTAssertEqual(gate.expire("t1", generation: second), .append([]))
    }

    /// A remount asks again; it does not drop what the first mount was holding.
    func testAReattachKeepsWhatWasHeld() {
        var gate = ScrollbackGate()
        _ = gate.attach("t1")
        _ = gate.output("t1", bytes("x"))
        let second = gate.attach("t1")

        XCTAssertEqual(gate.expire("t1", generation: second), .append([bytes("x")]))
    }

    func testAnAnsweredRequestDoesNotExpire() {
        var (gate, generation) = awaitingGate()
        _ = gate.scrollback("t1", bytes("history"))
        _ = gate.output("t1", bytes("live"))

        XCTAssertNil(gate.expire("t1", generation: generation))
    }

    // MARK: - socket loss

    /// No outstanding request will be answered on a dead socket, so nothing may
    /// stay held behind one.
    func testSocketLossClearsAwaiting() {
        var gate = ScrollbackGate()
        let generation = gate.attach("t1")
        _ = gate.attach("t2")

        _ = gate.clearAwaiting()

        XCTAssertFalse(gate.isAwaiting("t1"))
        XCTAssertFalse(gate.isAwaiting("t2"))
        XCTAssertEqual(gate.output("t1", bytes("live")), .append([bytes("live")]))
        XCTAssertNil(gate.expire("t1", generation: generation))
    }

    /// bridge.rs leaves these bytes buffered, where a later mount's deadline
    /// would deliver them ahead of that mount's own. Here they are handed back,
    /// to follow what the card shows: a held fragment is not its history.
    func testSocketLossReleasesWhatWasHeld() {
        var gate = ScrollbackGate()
        _ = gate.attach("t1")
        _ = gate.attach("t2")
        _ = gate.output("t1", bytes("one "))
        _ = gate.output("t1", bytes("two"))

        let released = gate.clearAwaiting()

        XCTAssertEqual(released, ["t1": .append([bytes("one "), bytes("two")])])
        XCTAssertEqual(gate.heldBytes("t1"), 0)
        XCTAssertEqual(gate.clearAwaiting(), [:])
    }
}
