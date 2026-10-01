import CoreGraphics
import XCTest
@testable import TarmacKit

/// A card gesture from press to release: what it does to the frame, when the
/// card lifts, and what the release commits.
final class CardGestureTests: XCTestCase {
    private let frame = CGRect(x: 40, y: 60, width: 300, height: 200)
    private let press = CGPoint(x: 100, y: 100)

    // MARK: - Header press

    func testAHeaderPressReleasedInPlaceIsAClickThatNeverLifts() {
        let gesture = CardGesture.headerPress(at: press, frame: frame)
        XCTAssertFalse(gesture.isLifted)
        XCTAssertEqual(gesture.outcome, .click)
    }

    func testAHeaderPressWithinTheThresholdMovesTheCardButStaysAClick() {
        var gesture = CardGesture.headerPress(at: press, frame: frame)
        XCTAssertEqual(
            gesture.frame(pointer: CGPoint(x: 102, y: 103), zoom: 1),
            CGRect(x: 42, y: 63, width: 300, height: 200)
        )
        XCTAssertFalse(gesture.isLifted)
        XCTAssertEqual(gesture.outcome, .click)
    }

    func testAHeaderPressPastTheThresholdLiftsAndReleasesAsAMove() {
        var gesture = CardGesture.headerPress(at: press, frame: frame)
        XCTAssertEqual(
            gesture.frame(pointer: CGPoint(x: 140, y: 90), zoom: 2),
            CGRect(x: 60, y: 55, width: 300, height: 200)
        )
        XCTAssertTrue(gesture.isLifted)
        XCTAssertEqual(gesture.outcome, .move)
    }

    func testAMoveBroughtBackToWhereItStartedIsStillAMove() {
        var gesture = CardGesture.headerPress(at: press, frame: frame)
        _ = gesture.frame(pointer: CGPoint(x: 150, y: 100), zoom: 1)
        XCTAssertEqual(gesture.frame(pointer: press, zoom: 1), frame)
        XCTAssertTrue(gesture.isLifted)
        XCTAssertEqual(gesture.outcome, .move)
    }

    func testAMoveNeverChangesTheCardsSize() {
        var gesture = CardGesture.headerPress(at: press, frame: frame)
        XCTAssertEqual(gesture.frame(pointer: CGPoint(x: 500, y: 700), zoom: 0.5).size, frame.size)
    }

    // MARK: - Handle press

    func testAHandlePressLiftsAtOnceAndReleasesAsAResizeEvenWithoutTravel() {
        let gesture = CardGesture.handlePress(.bottomRight, at: press, frame: frame)
        XCTAssertTrue(gesture.isLifted)
        XCTAssertEqual(gesture.outcome, .resize)
    }

    func testAResizeAppliesThePointerTravelDividedByTheZoom() {
        var gesture = CardGesture.handlePress(.bottomRight, at: press, frame: frame)
        XCTAssertEqual(
            gesture.frame(pointer: CGPoint(x: 140, y: 120), zoom: 2),
            CGRect(x: 40, y: 60, width: 320, height: 210)
        )
    }

    func testAResizeFromTheTopLeftMovesTheOriginAndPinsTheOppositeCorner() {
        var gesture = CardGesture.handlePress(.topLeft, at: press, frame: frame)
        XCTAssertEqual(
            gesture.frame(pointer: CGPoint(x: 90, y: 80), zoom: 1),
            CGRect(x: 30, y: 40, width: 310, height: 220)
        )
    }

    /// Each step resizes from the frame at the press, so a drag that pins at
    /// the minimum and comes back retraces its path instead of accumulating.
    func testAResizeIsMeasuredFromTheFrameAtThePressNotFromTheLastStep() {
        var gesture = CardGesture.handlePress(.right, at: press, frame: frame)
        XCTAssertEqual(gesture.frame(pointer: CGPoint(x: -400, y: 100), zoom: 1).width, CardResize.minWidth)
        XCTAssertEqual(gesture.frame(pointer: CGPoint(x: 110, y: 100), zoom: 1).width, 310)
    }

    func testAnEdgeResizeIgnoresTravelAlongTheEdge() {
        var gesture = CardGesture.handlePress(.bottom, at: press, frame: frame)
        XCTAssertEqual(
            gesture.frame(pointer: CGPoint(x: 400, y: 130), zoom: 1),
            CGRect(x: 40, y: 60, width: 300, height: 230)
        )
    }
}
