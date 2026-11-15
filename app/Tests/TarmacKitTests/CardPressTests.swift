import XCTest
@testable import TarmacKit

/// Which presses on a card select and raise it (spec 2607.0005: a press on a
/// link is the link's alone).
final class CardPressTests: XCTestCase {
    func testAPressOnACardSelectsIt() {
        XCTAssertTrue(CardPress.selects(.elsewhere))
    }

    func testAPressOnAHeaderControlIsTheControlsOwn() {
        XCTAssertFalse(CardPress.selects(.headerControl))
    }

    /// Following a link in a doc does not pick the doc up.
    func testAPressOnALinkInADocDoesNotSelectTheCard() {
        XCTAssertFalse(CardPress.selects(.link))
    }

    /// 2611.0015 D9, O10: a resume panel's button is outside its card. A press
    /// on it leaves the selection, which only the bare board clears.
    func testAPressOutsideEveryCardClearsTheSelectionOnlyOnTheBareBoard() {
        XCTAssertTrue(CardPress.clearsSelection(.elsewhere))
        XCTAssertFalse(CardPress.clearsSelection(.headerControl))
    }
}
