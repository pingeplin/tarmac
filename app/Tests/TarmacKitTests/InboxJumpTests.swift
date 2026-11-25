import XCTest

@testable import TarmacKit

/// Spec 2611.0013 "Jump plan flies or switches board first", "Jump to a gone card is dropped": where a jump from the inbox goes, and what it does
/// on arrival.
final class InboxJumpTests: XCTestCase {
    /// "Jump plan flies or switches board first".
    func testAnItemOnTheActiveBoardSwitchesNowhere() {
        XCTAssertNil(InboxJump.switchTarget(inboxItem(board: "board-0"), activeBoardID: "board-0"))
    }

    /// "Jump plan flies or switches board first".
    func testAnItemOnAnotherBoardSwitchesToItsBoard() {
        XCTAssertEqual(InboxJump.switchTarget(inboxItem(board: "board-1"), activeBoardID: "board-0"), "board-1")
    }

    /// "Jump plan flies or switches board first".
    func testALiveCardIsPrimedAndADeadOneSelected() {
        XCTAssertEqual(InboxJump.land(cardExists: true, cardDead: false), .prime)
        XCTAssertEqual(InboxJump.land(cardExists: true, cardDead: true), .select)
    }

    /// "Jump to a gone card is dropped".
    func testNoCardDropsTheItem() {
        XCTAssertEqual(InboxJump.land(cardExists: false, cardDead: false), .drop)
        XCTAssertEqual(InboxJump.land(cardExists: false, cardDead: true), .drop)
    }
}
