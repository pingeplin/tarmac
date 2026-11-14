import XCTest
@testable import TarmacKit

/// Spec 2611.0013 S6, S36: where a jump from the inbox goes, and what it does
/// on arrival.
final class InboxJumpTests: XCTestCase {
    private func item(board: String) -> Inbox.Item {
        Inbox.Item(kind: .bell, termID: "T", boardID: board, atMs: 0, proc: nil, cwd: nil, text: nil, read: false)
    }

    func testS6AnItemOnTheActiveBoardFlies() {
        XCTAssertEqual(InboxJump.plan(item(board: "board-0"), activeBoardID: "board-0"), .fly(termID: "T"))
    }

    func testS6AnItemOnAnotherBoardSwitchesThenFlies() {
        XCTAssertEqual(
            InboxJump.plan(item(board: "board-1"), activeBoardID: "board-0"),
            .switchThenFly(boardID: "board-1", termID: "T")
        )
    }

    func testS6ALiveCardIsPrimedAndADeadOneSelected() {
        XCTAssertEqual(InboxJump.land(cardExists: true, cardDead: false), .prime)
        XCTAssertEqual(InboxJump.land(cardExists: true, cardDead: true), .select)
    }

    func testS36NoCardDropsTheItem() {
        XCTAssertEqual(InboxJump.land(cardExists: false, cardDead: false), .drop)
        XCTAssertEqual(InboxJump.land(cardExists: false, cardDead: true), .drop)
    }
}
