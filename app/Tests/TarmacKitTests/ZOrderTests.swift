import XCTest
@testable import TarmacKit

/// A press puts a card above every card on the board, whatever its kind.
final class ZOrderTests: XCTestCase {
    func testTheTopIsTheHighestZOnTheBoard() {
        XCTAssertEqual(ZOrder.top([15, 10, 3]), 15)
    }

    func testAnEmptyBoardTopsOutAtZero() {
        XCTAssertEqual(ZOrder.top([Int]()), 0)
    }

    func testNegativeZsDoNotPullTheTopBelowZero() {
        XCTAssertEqual(ZOrder.top([-4, -1]), 0)
    }

    func testARaisedCardSitsStrictlyAboveEveryOther() {
        let zs = [5, 10]
        XCTAssertEqual(ZOrder.raised(above: zs), 11)
        for z in zs { XCTAssertGreaterThan(ZOrder.raised(above: zs), z) }
    }

    func testTheCardAlreadyOnTopStillMovesUp() {
        XCTAssertEqual(ZOrder.raised(above: [3, 7]), 8)
        XCTAssertEqual(ZOrder.raised(above: [7]), 8)
    }

    func testTheFirstCardOnAnEmptyBoardTakesOne() {
        XCTAssertEqual(ZOrder.raised(above: [Int]()), 1)
    }
}
