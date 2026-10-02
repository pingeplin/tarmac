import XCTest
@testable import TarmacKit

/// Whose answer a finished file read is. A scheme task is known by its
/// address, and a stopped task's address is free for the next task to take.
final class PendingReadsTests: XCTestCase {
    func testAReadIsAnsweredToTheRequestThatAskedForIt() {
        var reads = PendingReads<String, String>()
        let ticket = reads.start("a", for: "task A")
        XCTAssertEqual(reads.finish(ticket), "task A")
    }

    func testAStoppedRequestIsNeverAnswered() {
        var reads = PendingReads<String, String>()
        let ticket = reads.start("a", for: "task A")
        reads.stop("a")
        XCTAssertNil(reads.finish(ticket))
    }

    /// The stopped task's read comes back after a new task took its address:
    /// that read is nobody's, and the new task still gets its own.
    func testARequestAtAReusedAddressIsNotAnsweredWithTheStoppedOnesRead() {
        var reads = PendingReads<String, String>()
        let stale = reads.start("address", for: "task A")
        reads.stop("address")
        let fresh = reads.start("address", for: "task B")
        XCTAssertNil(reads.finish(stale))
        XCTAssertEqual(reads.finish(fresh), "task B")
    }

    /// Without a stop in between, a second start at the same address replaces
    /// the first; the first read is not the second task's.
    func testARestartedAddressKeepsOnlyItsLatestRequest() {
        var reads = PendingReads<String, String>()
        let first = reads.start("address", for: "task A")
        let second = reads.start("address", for: "task B")
        XCTAssertNil(reads.finish(first))
        XCTAssertEqual(reads.finish(second), "task B")
    }

    func testARequestIsAnsweredOnce() {
        var reads = PendingReads<String, String>()
        let ticket = reads.start("a", for: "task A")
        _ = reads.finish(ticket)
        XCTAssertNil(reads.finish(ticket))
    }

    func testRequestsAtDifferentAddressesDoNotDisturbEachOther() {
        var reads = PendingReads<String, String>()
        let a = reads.start("a", for: "task A")
        let b = reads.start("b", for: "task B")
        reads.stop("a")
        XCTAssertEqual(reads.finish(b), "task B")
        XCTAssertNil(reads.finish(a))
    }
}
