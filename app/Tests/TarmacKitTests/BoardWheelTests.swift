import CoreGraphics
import XCTest
@testable import TarmacKit

/// Wheel routing is keyed on the one selected card; a pinch always zooms.
final class BoardWheelTests: XCTestCase {
    private func route(
        pinch: Bool = false, over: String?, inBody: Bool = true, onThumb: Bool = false, selected: String?
    ) -> BoardWheel.Route {
        BoardWheel.route(pinch: pinch, over: over, inBody: inBody, onThumb: onThumb, selected: selected)
    }

    /// The thumb lies over the body: a wheel on it is the card's (spec
    /// 2610.0004).
    func test2610_0004S7AWheelOverTheSelectedCardsThumbIsThatCards() {
        XCTAssertEqual(route(over: "a", inBody: false, onThumb: true, selected: "a"), .card)
        XCTAssertEqual(route(over: "a", inBody: false, onThumb: true, selected: "b"), .pan)
        XCTAssertEqual(route(over: "a", inBody: false, onThumb: true, selected: nil), .pan)
        XCTAssertEqual(route(pinch: true, over: "a", inBody: false, onThumb: true, selected: "a"), .zoom)
    }

    // MARK: - Routing

    func testAWheelOverTheSelectedCardsBodyScrollsThatCard() {
        XCTAssertEqual(route(over: "a", selected: "a"), .card)
    }

    func testAWheelOverTheSelectedCardsHeaderPansTheBoard() {
        XCTAssertEqual(route(over: "a", inBody: false, selected: "a"), .pan)
    }

    func testAWheelOverAnUnselectedCardPansTheBoard() {
        XCTAssertEqual(route(over: "b", selected: "a"), .pan)
        XCTAssertEqual(route(over: "b", selected: nil), .pan)
    }

    func testAWheelOverTheBareBoardPansEvenWithACardSelected() {
        XCTAssertEqual(route(over: nil, selected: "a"), .pan)
        XCTAssertEqual(route(over: nil, selected: nil), .pan)
    }

    func testAPinchZoomsTheBoardEvenOverTheSelectedCardsBody() {
        XCTAssertEqual(route(pinch: true, over: "a", selected: "a"), .zoom)
        XCTAssertEqual(route(pinch: true, over: nil, selected: nil), .zoom)
    }

    // MARK: - Zoom factors

    func testAStillWheelDoesNotZoom() {
        XCTAssertEqual(BoardWheel.zoomFactor(deltaY: 0), 1)
    }

    func testScrollingDownZoomsOutAndUpZoomsInByTheSameRatio() {
        XCTAssertEqual(BoardWheel.zoomFactor(deltaY: 100), exp(-1), accuracy: 1e-12)
        XCTAssertEqual(BoardWheel.zoomFactor(deltaY: -100), exp(1), accuracy: 1e-12)
        XCTAssertEqual(BoardWheel.zoomFactor(deltaY: 10) * BoardWheel.zoomFactor(deltaY: -10), 1, accuracy: 1e-12)
    }

    func testAMagnifyStepScalesByOnePlusItsMagnification() {
        XCTAssertEqual(BoardWheel.zoomFactor(magnification: 0), 1)
        XCTAssertEqual(BoardWheel.zoomFactor(magnification: 0.05), 1.05)
        XCTAssertEqual(BoardWheel.zoomFactor(magnification: -0.25), 0.75)
    }

    // MARK: - Travel

    func testATrackpadTravelsByItsDeltaInScreenPoints() {
        XCTAssertEqual(
            BoardWheel.travel(scrollingDelta: CGVector(dx: 3, dy: -4), precise: true),
            CGVector(dx: 3, dy: -4)
        )
    }

    func testANotchedWheelReportsLinesWhichTravelTenPointsEach() {
        XCTAssertEqual(
            BoardWheel.travel(scrollingDelta: CGVector(dx: 3, dy: -4), precise: false),
            CGVector(dx: 30, dy: -40)
        )
    }

    /// AppKit's delta is the content's travel — the web's `deltaY` negated —
    /// so travelling up zooms in.
    func testAControlWheelZoomsByItsVerticalTravelWithTheWebsSignFlipped() {
        XCTAssertEqual(BoardWheel.zoomFactor(travel: CGVector(dx: 50, dy: 100)), exp(1), accuracy: 1e-12)
        XCTAssertEqual(BoardWheel.zoomFactor(travel: CGVector(dx: 0, dy: -100)), exp(-1), accuracy: 1e-12)
        XCTAssertEqual(
            BoardWheel.zoomFactor(travel: CGVector(dx: 0, dy: 25)), BoardWheel.zoomFactor(deltaY: -25), accuracy: 1e-12
        )
    }
}
