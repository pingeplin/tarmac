import CoreGraphics
import XCTest
@testable import TarmacKit

/// The resize hit areas: eight always-live zones in screen points, one fewer
/// and a shorter top strip beside a close button.
final class CardHandlesTests: XCTestCase {
    private let size = CGSize(width: 200, height: 120)

    private func hit(_ x: CGFloat, _ y: CGFloat, hasClose: Bool = false, size: CGSize? = nil) -> CardResize.Handle? {
        CardHandles.handle(at: CGPoint(x: x, y: y), cardSize: size ?? self.size, hasClose: hasClose)
    }

    // MARK: - The handle set

    func testACardWithoutACloseButtonHasAllEightHandles() {
        XCTAssertEqual(
            Set(CardHandles.handles(hasClose: false).map(String.init(describing:))),
            ["topLeft", "top", "topRight", "right", "bottomRight", "bottom", "bottomLeft", "left"]
        )
        XCTAssertEqual(CardHandles.handles(hasClose: false).count, 8)
    }

    func testACloseButtonRemovesOnlyTheTopRightCorner() {
        let handles = CardHandles.handles(hasClose: true)
        XCTAssertEqual(handles.count, 7)
        XCTAssertFalse(handles.contains(.topRight))
    }

    // MARK: - Zones

    func testCornersAreTwentyPointSquaresAtTheCardCorners() {
        XCTAssertEqual(CardHandles.zone(.topLeft, cardSize: size, hasClose: false), CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(CardHandles.zone(.topRight, cardSize: size, hasClose: false), CGRect(x: 180, y: 0, width: 20, height: 20))
        XCTAssertEqual(CardHandles.zone(.bottomLeft, cardSize: size, hasClose: false), CGRect(x: 0, y: 100, width: 20, height: 20))
        XCTAssertEqual(CardHandles.zone(.bottomRight, cardSize: size, hasClose: false), CGRect(x: 180, y: 100, width: 20, height: 20))
    }

    func testEdgeStripsAreSixThickAndStopTwentyShortOfEachCorner() {
        XCTAssertEqual(CardHandles.zone(.top, cardSize: size, hasClose: false), CGRect(x: 20, y: 0, width: 160, height: 6))
        XCTAssertEqual(CardHandles.zone(.bottom, cardSize: size, hasClose: false), CGRect(x: 20, y: 114, width: 160, height: 6))
        XCTAssertEqual(CardHandles.zone(.left, cardSize: size, hasClose: false), CGRect(x: 0, y: 20, width: 6, height: 80))
        XCTAssertEqual(CardHandles.zone(.right, cardSize: size, hasClose: false), CGRect(x: 194, y: 20, width: 6, height: 80))
    }

    func testTheTopStripStopsThirtyTwoShortOfTheRightEdgeBesideACloseButton() {
        XCTAssertEqual(CardHandles.zone(.top, cardSize: size, hasClose: true), CGRect(x: 20, y: 0, width: 148, height: 6))
        XCTAssertEqual(CardHandles.zone(.bottom, cardSize: size, hasClose: true), CGRect(x: 20, y: 114, width: 160, height: 6))
    }

    func testTheTopRightCornerHasNoZoneBesideACloseButton() {
        XCTAssertNil(CardHandles.zone(.topRight, cardSize: size, hasClose: true))
    }

    func testAStripWithNoRoomBetweenItsCornersHasNoZone() {
        let tiny = CGSize(width: 40, height: 30)
        XCTAssertNil(CardHandles.zone(.top, cardSize: tiny, hasClose: false))
        XCTAssertNil(CardHandles.zone(.left, cardSize: tiny, hasClose: false))
        XCTAssertNotNil(CardHandles.zone(.topLeft, cardSize: tiny, hasClose: false))
    }

    // MARK: - Hit testing

    func testAPointInACornerHitsThatCorner() {
        XCTAssertEqual(hit(3, 3), .topLeft)
        XCTAssertEqual(hit(197, 3), .topRight)
        XCTAssertEqual(hit(3, 117), .bottomLeft)
        XCTAssertEqual(hit(197, 117), .bottomRight)
    }

    func testAPointOnAnEdgeStripHitsThatEdge() {
        XCTAssertEqual(hit(100, 2), .top)
        XCTAssertEqual(hit(100, 118), .bottom)
        XCTAssertEqual(hit(2, 60), .left)
        XCTAssertEqual(hit(198, 60), .right)
    }

    func testTheInteriorAndTheOutsideHitNothing() {
        XCTAssertNil(hit(100, 60))
        XCTAssertNil(hit(100, 6))
        XCTAssertNil(hit(6, 60))
        XCTAssertNil(hit(-1, 3))
        XCTAssertNil(hit(200, 3))
        XCTAssertNil(hit(100, 120))
    }

    func testZonesAreHalfOpenSoTheStripStartsWhereTheCornerEnds() {
        XCTAssertEqual(hit(19.9, 2), .topLeft)
        XCTAssertEqual(hit(20, 2), .top)
        XCTAssertEqual(hit(179.9, 2), .top)
        XCTAssertEqual(hit(180, 2), .topRight)
    }

    func testBesideACloseButtonTheTopRightCornerAndTheReservedStripAreDead() {
        XCTAssertNil(hit(190, 3, hasClose: true))
        XCTAssertNil(hit(170, 3, hasClose: true))
        XCTAssertEqual(hit(167.9, 3, hasClose: true), .top)
        XCTAssertEqual(hit(198, 30, hasClose: true), .right)
    }

    /// At a low zoom a card is smaller on screen than two corners: the corners
    /// overlap and the one painted last wins, as stacked elements do.
    func testOverlappingCornersResolveToTheOnePaintedLast() {
        let tiny = CGSize(width: 30, height: 24)
        XCTAssertEqual(hit(15, 12, size: tiny), .bottomLeft)
        XCTAssertEqual(hit(25, 12, size: tiny), .bottomRight)
        XCTAssertEqual(hit(25, 2, size: tiny), .topRight)
        XCTAssertEqual(hit(5, 2, size: tiny), .topLeft)
    }

    func testOnACardShorterThanTwoCornersTheSideEdgesAreAllCorner() {
        let short = CGSize(width: 200, height: 30)
        XCTAssertEqual(hit(3, 5, size: short), .topLeft)
        XCTAssertEqual(hit(3, 15, size: short), .bottomLeft)
        XCTAssertEqual(hit(197, 15, size: short), .bottomRight)
        XCTAssertEqual(hit(100, 27, size: short), .bottom)
    }

    // MARK: - Cursors

    func testEachHandleShowsTheCursorForItsAxis() {
        XCTAssertEqual(CardHandles.cursor(for: .topLeft), .diagonalDown)
        XCTAssertEqual(CardHandles.cursor(for: .bottomRight), .diagonalDown)
        XCTAssertEqual(CardHandles.cursor(for: .topRight), .diagonalUp)
        XCTAssertEqual(CardHandles.cursor(for: .bottomLeft), .diagonalUp)
        XCTAssertEqual(CardHandles.cursor(for: .top), .vertical)
        XCTAssertEqual(CardHandles.cursor(for: .bottom), .vertical)
        XCTAssertEqual(CardHandles.cursor(for: .left), .horizontal)
        XCTAssertEqual(CardHandles.cursor(for: .right), .horizontal)
    }
}
