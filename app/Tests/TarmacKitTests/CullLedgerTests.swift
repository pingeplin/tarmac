import XCTest
@testable import TarmacKit

/// A cull pass reports a card only when its visibility is new or has flipped.
final class CullLedgerTests: XCTestCase {
    func testTheFirstSightingOfACardIsReportedWhicheverWayItFalls() {
        var ledger = CullLedger<String>()
        XCTAssertTrue(ledger.record("shown", visible: true))
        XCTAssertTrue(ledger.record("hidden", visible: false))
    }

    func testAnUnchangedStateIsNotReportedAgain() {
        var ledger = CullLedger<String>()
        _ = ledger.record("a", visible: true)
        XCTAssertFalse(ledger.record("a", visible: true))
        XCTAssertFalse(ledger.record("a", visible: true))
    }

    func testEachFlipIsReportedOnce() {
        var ledger = CullLedger<String>()
        _ = ledger.record("a", visible: true)
        XCTAssertTrue(ledger.record("a", visible: false))
        XCTAssertFalse(ledger.record("a", visible: false))
        XCTAssertTrue(ledger.record("a", visible: true))
    }

    func testCardsAreTrackedIndependently() {
        var ledger = CullLedger<String>()
        _ = ledger.record("a", visible: true)
        _ = ledger.record("b", visible: true)
        XCTAssertTrue(ledger.record("a", visible: false))
        XCTAssertFalse(ledger.record("b", visible: true))
    }

    func testAForgottenCardIsReportedAfreshWhenItComesBack() {
        var ledger = CullLedger<String>()
        _ = ledger.record("a", visible: true)
        ledger.forget("a")
        XCTAssertTrue(ledger.record("a", visible: true))
    }
}
