import XCTest
import TarmacKit

/// 2609.0018: the key-held override `tarmac dev press` arms on the release poll.
final class KeyHoldTests: XCTestCase {
    private let hold = KeyHold(keyCode: 12, untilMs: 5_000)

    func testTheKeyReadsAsHeldUntilTheDeadline() {
        XCTAssertTrue(hold.holds(12, nowMs: 0))
        XCTAssertTrue(hold.holds(12, nowMs: 4_999))
    }

    func testTheHoldEndsAtTheDeadline() {
        XCTAssertFalse(hold.holds(12, nowMs: 5_000))
        XCTAssertFalse(hold.holds(12, nowMs: 9_000))
    }

    /// The poller samples the key that started the gesture, which a later press
    /// of another chord must not hold down.
    func testAnotherKeyIsNotHeld() {
        XCTAssertFalse(hold.holds(13, nowMs: 0))
    }
}
