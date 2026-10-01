import XCTest
@testable import TarmacKit

/// How long a verb that dispatched input waits before it builds its reply
/// (spec 2609.0015, #166; parity row Q20).
final class DevSettleTests: XCTestCase {
    func testTwoFramesSettleTheUI() {
        XCTAssertFalse(DevSettle.isSettled(framesSeen: 0, elapsedMs: 0))
        XCTAssertFalse(DevSettle.isSettled(framesSeen: 1, elapsedMs: 16))
        XCTAssertTrue(DevSettle.isSettled(framesSeen: 2, elapsedMs: 21))
        XCTAssertTrue(DevSettle.isSettled(framesSeen: 3, elapsedMs: 40))
    }

    /// A hidden or minimised window services no frames at all, so the cap is
    /// what ends the wait there; it can only ever end one early.
    func testTheCapEndsAWaitThatSeesNoFrames() {
        XCTAssertFalse(DevSettle.isSettled(framesSeen: 0, elapsedMs: 99))
        XCTAssertTrue(DevSettle.isSettled(framesSeen: 0, elapsedMs: 100))
        XCTAssertTrue(DevSettle.isSettled(framesSeen: 1, elapsedMs: 250))
    }
}
