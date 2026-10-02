import XCTest
@testable import TarmacKit

/// Many changes, one update: a view that is told of every change schedules a
/// single refresh to cover them all.
final class CoalescedUpdateTests: XCTestCase {
    func testTheFirstChangeAsksForAnUpdate() {
        var update = CoalescedUpdate()
        XCTAssertTrue(update.changed())
    }

    func testFurtherChangesRideOnTheUpdateAlreadyAskedFor() {
        var update = CoalescedUpdate()
        _ = update.changed()
        XCTAssertFalse(update.changed())
        XCTAssertFalse(update.changed())
    }

    func testAChangeAfterTheUpdateRanAsksForAnother() {
        var update = CoalescedUpdate()
        _ = update.changed()
        update.ran()
        XCTAssertTrue(update.changed())
        XCTAssertFalse(update.changed())
    }
}
