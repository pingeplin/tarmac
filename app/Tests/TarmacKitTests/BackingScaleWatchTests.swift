import CoreGraphics
import XCTest
@testable import TarmacKit

/// Which "backing properties changed" callbacks are about the display. AppKit
/// sends one for every step of a board zoom too, since a scaled ancestor
/// changes a view's effective density.
final class BackingScaleWatchTests: XCTestCase {
    func testTheFirstScaleSeenIsAChange() {
        var watch = BackingScaleWatch()
        XCTAssertTrue(watch.changed(to: 2))
    }

    func testTheSameScaleAgainIsNotAChange() {
        var watch = BackingScaleWatch()
        _ = watch.changed(to: 2)
        XCTAssertFalse(watch.changed(to: 2))
        XCTAssertFalse(watch.changed(to: 2))
    }

    func testAnotherDisplaysScaleIsAChange() {
        var watch = BackingScaleWatch()
        _ = watch.changed(to: 2)
        XCTAssertTrue(watch.changed(to: 1))
        XCTAssertFalse(watch.changed(to: 1))
        XCTAssertTrue(watch.changed(to: 2))
    }

    /// A view out of a window has no scale; that is not a change, and the
    /// scale it had is remembered for when it comes back.
    func testNoWindowIsNotAChange() {
        var watch = BackingScaleWatch()
        _ = watch.changed(to: 2)
        XCTAssertFalse(watch.changed(to: nil))
        XCTAssertFalse(watch.changed(to: 2))
    }
}
