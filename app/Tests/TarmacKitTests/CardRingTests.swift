import XCTest
@testable import TarmacKit

/// The ring outside a card's border: teal on a doc an agent just opened, amber
/// on the borrowed HTML card.
final class CardRingTests: XCTestCase {
    func testAPlainCardHasNoRing() {
        XCTAssertNil(CardRing.of(fresh: false, borrowed: false))
    }

    func testAFreshDocWearsTheFreshRing() {
        XCTAssertEqual(CardRing.of(fresh: true, borrowed: false), .fresh)
    }

    func testABorrowedCardWearsTheBorrowRing() {
        XCTAssertEqual(CardRing.of(fresh: false, borrowed: true), .borrowed)
    }

    /// One ring at a time: holding the keyboard is the louder of the two.
    func testBorrowedOutranksFresh() {
        XCTAssertEqual(CardRing.of(fresh: true, borrowed: true), .borrowed)
    }
}
