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
}
