import CoreGraphics
import XCTest
@testable import TarmacKit

/// A header press: the card follows the pointer at once, but it is a move only
/// past 3 screen points of travel.
final class CardDragTests: XCTestCase {
    private func drag() -> CardDrag {
        CardDrag(pressPoint: CGPoint(x: 100, y: 100), startOrigin: CGPoint(x: 40, y: 60))
    }

    func testAPressThatHasNotTravelledIsNotAMove() {
        XCTAssertFalse(drag().moved)
    }

    func testTheCardFollowsThePointerByItsTravelDividedByTheZoom() {
        var d = drag()
        XCTAssertEqual(d.origin(pointer: CGPoint(x: 120, y: 90), zoom: 2), CGPoint(x: 50, y: 55))
        XCTAssertEqual(d.origin(pointer: CGPoint(x: 80, y: 130), zoom: 0.5), CGPoint(x: 0, y: 120))
    }

    func testTheCardFollowsEvenWithinTheThreshold() {
        var d = drag()
        XCTAssertEqual(d.origin(pointer: CGPoint(x: 102, y: 101), zoom: 1), CGPoint(x: 42, y: 61))
        XCTAssertFalse(d.moved)
    }

    func testExactlyThreePointsOfTravelIsStillAClick() {
        var d = drag()
        _ = d.origin(pointer: CGPoint(x: 103, y: 97), zoom: 1)
        XCTAssertFalse(d.moved)
    }

    func testMoreThanThreePointsOnEitherAxisIsAMove() {
        var horizontal = drag()
        _ = horizontal.origin(pointer: CGPoint(x: 103.5, y: 100), zoom: 1)
        XCTAssertTrue(horizontal.moved)

        var vertical = drag()
        _ = vertical.origin(pointer: CGPoint(x: 100, y: 96), zoom: 1)
        XCTAssertTrue(vertical.moved)
    }

    /// The threshold is travel on screen, so a zoomed-out board does not turn a
    /// 2-point jitter (20 world units at zoom 0.1) into a move.
    func testTheThresholdIsMeasuredOnScreenNotInWorldUnits() {
        var d = drag()
        XCTAssertEqual(d.origin(pointer: CGPoint(x: 102, y: 100), zoom: 0.1), CGPoint(x: 60, y: 60))
        XCTAssertFalse(d.moved)
    }

    func testAMoveStaysAMoveWhenThePointerComesBack() {
        var d = drag()
        _ = d.origin(pointer: CGPoint(x: 110, y: 100), zoom: 1)
        XCTAssertEqual(d.origin(pointer: CGPoint(x: 100, y: 100), zoom: 1), CGPoint(x: 40, y: 60))
        XCTAssertTrue(d.moved)
    }
}
