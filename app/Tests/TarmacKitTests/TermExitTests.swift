import XCTest
@testable import TarmacKit

/// 2606.0001: the exit→action decision and the persisted-tile partition.
final class TermExitTests: XCTestCase {
    /// S10: the full decision grid. `code ∈ {0, 1, 130, nil}` × `otherLive ∈
    /// {0, 2}`. `130` (128 + SIGINT) guards "any non-zero → holdOpen" against a
    /// mutation that special-cases high/negative codes. The `(_, 0)` failure
    /// cells must be `.holdOpen`, NOT `.removeAndReplace` — failure wins over the
    /// last-terminal guarantee (S8b).
    func testDecideGrid() {
        let cases: [(code: Int?, otherLive: Int, expected: TermExit.Action)] = [
            (0, 2, .remove),
            (0, 0, .removeAndReplace),
            (1, 2, .holdOpen),
            (1, 0, .holdOpen),
            (130, 2, .holdOpen),
            (130, 0, .holdOpen),
            (nil, 2, .holdOpen),
            (nil, 0, .holdOpen),
        ]
        for c in cases {
            XCTAssertEqual(
                TermExit.decide(code: c.code, otherLiveTerminals: c.otherLive),
                c.expected,
                "decide(code: \(c.code.map(String.init) ?? "nil"), otherLiveTerminals: \(c.otherLive))"
            )
        }
    }

    /// S3-vs-S1 boundary, pinned on its own so the mutation is unmissable: a clean
    /// exit flips `.remove` → `.removeAndReplace` exactly when it was the last
    /// live terminal.
    func testCleanExitLastTerminalReplacesOnlyAtZero() {
        XCTAssertEqual(TermExit.decide(code: 0, otherLiveTerminals: 1), .remove)
        XCTAssertEqual(TermExit.decide(code: 0, otherLiveTerminals: 0), .removeAndReplace)
    }

    func testPersistsTileExcludesExited() {
        XCTAssertTrue(TermExit.persistsTile(exited: false))
        XCTAssertFalse(TermExit.persistsTile(exited: true))
    }

    /// S6 / S9: the partition keeps live AND detached survivors (both `exited ==
    /// false`) and drops only exited tiles, preserving order. The "detached"
    /// entry stands in for a reconnect survivor whose `live == false` — keying
    /// the partition off liveness instead of `exited` would wrongly drop it.
    func testPersistedTermIDsKeepsSurvivorsDropsExited() {
        let tiles: [(termID: String, exited: Bool)] = [
            ("live", false),
            ("detached", false),   // reconnect survivor: live == false, but NOT exited
            ("exited", true),      // clean-removed-or-held-open: dropped
        ]
        XCTAssertEqual(TermExit.persistedTermIDs(tiles), ["live", "detached"])
    }

    func testPersistedTermIDsEmpty() {
        XCTAssertEqual(TermExit.persistedTermIDs([]), [])
    }
}
