import XCTest
@testable import TarmacKit

final class PendingPersistsTests: XCTestCase {
    func testTheDebounceIs200Ms() {
        XCTAssertEqual(PendingPersists.debounceMs, 200)
    }

    func testAScheduledBoardIsDueWhenItsTimerFires() {
        var pending = PendingPersists()
        let token = pending.schedule("board-0")

        XCTAssertTrue(pending.isPending("board-0"))
        XCTAssertTrue(pending.fire("board-0", token: token))
        XCTAssertFalse(pending.isPending("board-0"))
    }

    func testATimerFiresOnce() {
        var pending = PendingPersists()
        let token = pending.schedule("board-0")
        _ = pending.fire("board-0", token: token)

        XCTAssertFalse(pending.fire("board-0", token: token))
    }

    /// A burst of changes is one snapshot: only the last timer counts.
    func testReschedulingSupersedesTheEarlierTimer() {
        var pending = PendingPersists()
        let first = pending.schedule("board-0")
        let second = pending.schedule("board-0")

        XCTAssertFalse(pending.fire("board-0", token: first))
        XCTAssertTrue(pending.isPending("board-0"), "the board still owes its snapshot")
        XCTAssertTrue(pending.fire("board-0", token: second))
    }

    func testEachBoardWaitsOnItsOwn() {
        var pending = PendingPersists()
        let background = pending.schedule("board-0")
        let active = pending.schedule("board-1")
        _ = pending.schedule("board-1")

        XCTAssertTrue(pending.fire("board-0", token: background), "another board's change must not restart it")
        XCTAssertFalse(pending.fire("board-1", token: active))
        XCTAssertFalse(pending.fire("board-1", token: background), "a token belongs to the board it was issued for")
    }

    func testFlushingABoardThatOwesASnapshotSendsItNowAndDisarmsItsTimer() {
        var pending = PendingPersists()
        let token = pending.schedule("board-0")

        XCTAssertTrue(pending.flush("board-0"))
        XCTAssertFalse(pending.isPending("board-0"))
        XCTAssertFalse(pending.fire("board-0", token: token))
    }

    func testFlushingABoardThatOwesNothingSendsNothing() {
        var pending = PendingPersists()
        _ = pending.schedule("board-1")

        XCTAssertFalse(pending.flush("board-0"))
        XCTAssertTrue(pending.isPending("board-1"))
    }

    func testFlushAllReturnsEveryPendingBoardOnce() {
        var pending = PendingPersists()
        _ = pending.schedule("board-1")
        _ = pending.schedule("board-0")
        _ = pending.schedule("board-1")

        XCTAssertEqual(pending.flushAll(), ["board-0", "board-1"])
        XCTAssertEqual(pending.flushAll(), [])
    }

    /// A pruned board's timer must not send a snapshot for a board that is gone.
    func testCancellingABoardDisarmsItsTimer() {
        var pending = PendingPersists()
        let token = pending.schedule("board-0")

        pending.cancel("board-0")

        XCTAssertFalse(pending.isPending("board-0"))
        XCTAssertFalse(pending.fire("board-0", token: token))
        XCTAssertEqual(pending.flushAll(), [])
    }
}
