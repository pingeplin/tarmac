import XCTest
@testable import TarmacKit

/// Fresh is set by a `tarmac open` and by nothing else an open can carry.
final class CardFreshTests: XCTestCase {
    func testACliOpenMakesANewCardFresh() {
        XCTAssertTrue(CardFresh.afterOpen(via: "cli", wasFresh: false))
    }

    func testACliReopenOfACardAlreadyOnTheBoardMakesItFreshAgain() {
        XCTAssertTrue(CardFresh.afterOpen(via: "cli", wasFresh: true))
    }

    func testAnOpenThatDidNotComeFromTheCliLandsWithoutTheHighlight() {
        XCTAssertFalse(CardFresh.afterOpen(via: "user", wasFresh: false))
    }

    func testAnOpenThatDidNotComeFromTheCliLeavesAFreshCardFresh() {
        XCTAssertTrue(CardFresh.afterOpen(via: "user", wasFresh: true))
    }
}
