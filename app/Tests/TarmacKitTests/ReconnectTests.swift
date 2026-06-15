import XCTest
@testable import TarmacKit

/// P5.3: the bounded auto-reconnect backoff schedule.
final class ReconnectTests: XCTestCase {
    func testRampThenCap() {
        XCTAssertEqual(Reconnect.delay(forAttempt: 1), 0.5)
        XCTAssertEqual(Reconnect.delay(forAttempt: 2), 1)
        XCTAssertEqual(Reconnect.delay(forAttempt: 3), 2)
        XCTAssertEqual(Reconnect.delay(forAttempt: 4), 4)
        XCTAssertEqual(Reconnect.delay(forAttempt: 5), 8)
        // Past the ramp it holds at the 15 s cap.
        XCTAssertEqual(Reconnect.delay(forAttempt: 6), 15)
        XCTAssertEqual(Reconnect.delay(forAttempt: Reconnect.maxAttempts), 15)
    }

    func testGivesUpPastBudget() {
        XCTAssertNil(Reconnect.delay(forAttempt: Reconnect.maxAttempts + 1), "past the budget → stop retrying")
        XCTAssertNil(Reconnect.delay(forAttempt: 0), "attempt 0 is invalid")
        XCTAssertNil(Reconnect.delay(forAttempt: -1))
    }

    func testScheduleIsMonotonicAndCapped() {
        var last: TimeInterval = 0
        for n in 1...Reconnect.maxAttempts {
            let d = Reconnect.delay(forAttempt: n)!
            XCTAssertGreaterThanOrEqual(d, last, "delay must not decrease at attempt \(n)")
            XCTAssertLessThanOrEqual(d, 15, "delay must never exceed the 15 s cap at attempt \(n)")
            last = d
        }
    }
}
