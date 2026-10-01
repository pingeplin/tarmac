import XCTest
@testable import TarmacKit

/// The bottom-right toast stack's queue, expiry and overflow rules. Time is
/// injected (`nowMs`) so expiry is deterministic.
final class ToastQueueTests: XCTestCase {
    private func queue(adding ids: [String], at nowMs: Int = 0) -> ToastQueue {
        var queue = ToastQueue()
        for id in ids { queue.add(id: id, icon: "¶", title: id, nowMs: nowMs) }
        return queue
    }

    private func ids(_ queue: ToastQueue) -> [String] {
        queue.toasts.map(\.id)
    }

    // MARK: - add

    func testAddExpiresAtNowPlusTTLAndAppendsAsTheNewest() {
        var queue = ToastQueue()
        queue.add(id: "a", icon: "¶", title: "a", nowMs: 1000)
        XCTAssertEqual(queue.toasts.count, 1)
        XCTAssertEqual(queue.toasts.first?.expiresAtMs, 1000 + ToastQueue.ttlMs)
    }

    func testAddSaturatesTheExpiryInsteadOfOverflowingNearIntMax() {
        var queue = ToastQueue()
        queue.add(id: "a", icon: "¶", title: "a", nowMs: .max)
        XCTAssertEqual(queue.toasts.first?.expiresAtMs, .max)
        queue.add(id: "b", icon: "¶", title: "b", nowMs: .max - ToastQueue.ttlMs)
        XCTAssertEqual(queue.toasts.last?.expiresAtMs, .max)
        queue.add(id: "c", icon: "¶", title: "c", nowMs: .max - ToastQueue.ttlMs - 1)
        XCTAssertEqual(queue.toasts.last?.expiresAtMs, .max - 1)
    }

    func testAddKeepsTheNewestLastAcrossAdds() {
        XCTAssertEqual(ids(queue(adding: ["a", "b"])), ["a", "b"])
    }

    func testAddEvictsTheOldestBeyondMaxToastsKeepingTheRestInOrder() {
        let queue = queue(adding: ["a", "b", "c", "d"])
        XCTAssertEqual(queue.toasts.count, ToastQueue.maxToasts)
        XCTAssertEqual(ids(queue), ["b", "c", "d"])
    }

    func testAddDoesNotCoalesceIdenticalToasts() {
        var queue = ToastQueue()
        queue.add(id: "a", icon: "¶", title: "same", nowMs: 0)
        queue.add(id: "b", icon: "¶", title: "same", nowMs: 0)
        XCTAssertEqual(queue.toasts.count, 2)
    }

    func testAddCarriesTheBodyAndChipsThrough() {
        var queue = ToastQueue()
        queue.add(
            id: "a", icon: "›_", title: "exited", body: "code 1",
            chips: [ToastQueue.Chip(label: "undo")], nowMs: 0
        )
        XCTAssertEqual(queue.toasts.first?.icon, "›_")
        XCTAssertEqual(queue.toasts.first?.body, "code 1")
        XCTAssertEqual(queue.toasts.first?.chips, [ToastQueue.Chip(label: "undo")])
    }

    // MARK: - pruneExpired

    func testPruneKeepsAToastOneMsBeforeExpiryAndDropsItAtExpiry() {
        var queue = queue(adding: ["a"], at: 1000)
        queue.pruneExpired(nowMs: 1000 + ToastQueue.ttlMs - 1)
        XCTAssertEqual(queue.toasts.count, 1)
        queue.pruneExpired(nowMs: 1000 + ToastQueue.ttlMs)
        XCTAssertEqual(queue.toasts.count, 0)
    }

    // MARK: - dismiss

    func testDismissRemovesOnlyTheTargetedIDLeavingTheRestAndTheirExpiry() {
        var queue = ToastQueue()
        queue.add(id: "a", icon: "¶", title: "a", nowMs: 0)
        queue.add(id: "b", icon: "¶", title: "b", nowMs: 5)
        queue.dismiss(id: "a")
        XCTAssertEqual(ids(queue), ["b"])
        XCTAssertEqual(queue.toasts.first?.expiresAtMs, 5 + ToastQueue.ttlMs)
    }

    func testDismissOfAnUnknownIDChangesNothing() {
        var queue = queue(adding: ["a", "b"])
        queue.dismiss(id: "z")
        XCTAssertEqual(ids(queue), ["a", "b"])
    }

    // MARK: - clearAll

    func testClearAllEmptiesTheStackRegardlessOfExpiry() {
        var queue = queue(adding: ["a", "b"])
        queue.clearAll()
        XCTAssertEqual(queue.toasts.count, 0)
    }
}
