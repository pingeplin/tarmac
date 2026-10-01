import XCTest
@testable import TarmacKit

/// Spec 2607.0004: the one HTML card whose shield is down.
final class CardBorrowTests: XCTestCase {
    func testNothingIsBorrowedAtFirst() {
        let borrow = CardBorrow<String>()
        XCTAssertNil(borrow.id)
        XCTAssertFalse(borrow.shows("a", boardVisible: true))
    }

    func testBorrowingACardTakesItFromTheOneBorrowedBefore() {
        var borrow = CardBorrow<String>()
        borrow.borrow("a")
        borrow.borrow("b")
        XCTAssertFalse(borrow.shows("a", boardVisible: true))
        XCTAssertTrue(borrow.shows("b", boardVisible: true))
    }

    func testReleaseReportsWhetherACardWasBorrowed() {
        var borrow = CardBorrow<String>()
        XCTAssertFalse(borrow.release())
        borrow.borrow("a")
        XCTAssertTrue(borrow.release())
        XCTAssertNil(borrow.id)
    }

    /// A closed card cannot stay borrowed: the stale id would eat one ESC.
    func testClosingTheBorrowedCardReleasesIt() {
        var borrow = CardBorrow<String>()
        borrow.borrow("a")
        borrow.closed("a")
        XCTAssertNil(borrow.id)
    }

    func testClosingAnotherCardLeavesTheBorrowAlone() {
        var borrow = CardBorrow<String>()
        borrow.borrow("a")
        borrow.closed("b")
        XCTAssertEqual(borrow.id, "a")
    }

    /// A board switch does not release the borrow; the card on a hidden board
    /// is only drawn shielded.
    func testAHiddenBoardShowsItsBorrowedCardShielded() {
        var borrow = CardBorrow<String>()
        borrow.borrow("a")
        XCTAssertFalse(borrow.shows("a", boardVisible: false))
        XCTAssertEqual(borrow.id, "a")
    }
}
