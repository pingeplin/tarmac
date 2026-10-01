import CoreGraphics
import XCTest
@testable import TarmacKit

/// Wheel routing is keyed on the one selected card; a pinch always zooms.
final class BoardWheelTests: XCTestCase {
    private func route(pinch: Bool = false, over: String?, inBody: Bool = true, selected: String?) -> BoardWheel.Route {
        BoardWheel.route(pinch: pinch, over: over, inBody: inBody, selected: selected)
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
}
