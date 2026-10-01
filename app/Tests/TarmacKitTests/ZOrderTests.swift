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

    func testARaisedCardClearsZeroEvenWhenEveryCardIsBelowIt() {
        XCTAssertEqual(ZOrder.raised(above: [-4, -1]), 1)
    }

    // MARK: - Stacking

    func testAHigherZIsInFrontWhicheverCardWasAddedFirst() {
        XCTAssertLessThan(ZOrder.Place(z: 1, added: 9), ZOrder.Place(z: 2, added: 0))
        XCTAssertFalse(ZOrder.Place(z: 2, added: 0) < ZOrder.Place(z: 1, added: 9))
    }

    func testAmongEqualZsTheCardAddedLaterIsInFront() {
        XCTAssertLessThan(ZOrder.Place(z: 3, added: 0), ZOrder.Place(z: 3, added: 1))
        XCTAssertFalse(ZOrder.Place(z: 3, added: 1) < ZOrder.Place(z: 3, added: 0))
    }

    /// Restored tiles without a `z` all stack at zero, and must come out the
    /// same way every time.
    func testAStackOfTiesSortsTheSameWayFromAnyStartingOrder() {
        let stacked = [(0, 0), (0, 1), (0, 2), (5, 1)].map { ZOrder.Place(z: $0.0, added: $0.1) }
        XCTAssertEqual([stacked[3], stacked[2], stacked[0], stacked[1]].sorted(), stacked)
        XCTAssertEqual([stacked[1], stacked[0], stacked[3], stacked[2]].sorted(), stacked)
    }

    func testAPlaceIsNotInFrontOfItself() {
        XCTAssertFalse(ZOrder.Place(z: 3, added: 1) < ZOrder.Place(z: 3, added: 1))
    }
}
