import XCTest
@testable import TarmacKit

final class SpawnReadinessTests: XCTestCase {
    func testABoardBuiltAndRestoredOnALaidOutConnectionIsReady() {
        XCTAssertTrue(SpawnReadiness.ready(connected: true, viewReady: true, built: true, restored: true))
    }

    /// 2611.0016 S12: each gap holds the spawn, so `term_new` is refused.
    func testS12EachMissingConditionIsNotReady() {
        let cases: [(String, Bool, Bool, Bool, Bool)] = [
            ("built but not restored on this connection", true, true, true, false),
            ("restored on this connection but not built", true, true, false, true),
            ("neither built nor restored", true, true, false, false),
            ("not connected", false, true, true, true),
            ("the view not laid out", true, false, true, true),
        ]
        for (name, connected, viewReady, built, restored) in cases {
            XCTAssertFalse(
                SpawnReadiness.ready(connected: connected, viewReady: viewReady, built: built, restored: restored), name
            )
        }
    }
}
