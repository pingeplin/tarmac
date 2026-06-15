import XCTest
@testable import TarmacKit

/// P5: the re-bind-vs-cold-spawn partition for terminal restore.
final class TermRestoreTests: XCTestCase {
    func testLiveTileRebinds() {
        let plans = TermRestore.plan(tileTermIDs: ["t0"], liveTerms: ["t0"])
        XCTAssertEqual(plans, [.rebind(termID: "t0")])
    }

    func testDeadTileColdSpawns() {
        // The persisted id is not among the daemon's live terms (it exited, or the
        // daemon restarted) → cold-spawn.
        let plans = TermRestore.plan(tileTermIDs: ["t0"], liveTerms: [])
        XCTAssertEqual(plans, [.coldSpawn])
    }

    func testNilTermIDColdSpawns() {
        let plans = TermRestore.plan(tileTermIDs: [nil], liveTerms: ["t0"])
        XCTAssertEqual(plans, [.coldSpawn])
    }

    func testMixedPreservesTileOrder() {
        // Two shells survived (t0, t2), one died (t1) — each tile decides
        // independently and order is preserved (tile 0 becomes the prime).
        let plans = TermRestore.plan(tileTermIDs: ["t0", "t1", "t2"], liveTerms: ["t0", "t2"])
        XCTAssertEqual(plans, [.rebind(termID: "t0"), .coldSpawn, .rebind(termID: "t2")])
    }

    func testDaemonRestartAllColdSpawn() {
        // Empty liveTerms (daemon restarted, all shells gone) ⇒ every tile cold-
        // spawns — the pre-P5 behaviour, byte-for-byte.
        let plans = TermRestore.plan(tileTermIDs: ["t0", "t1"], liveTerms: [])
        XCTAssertEqual(plans, [.coldSpawn, .coldSpawn])
    }

    func testEmptyTilesEmptyPlan() {
        XCTAssertEqual(TermRestore.plan(tileTermIDs: [], liveTerms: ["t0"]), [])
    }
}
