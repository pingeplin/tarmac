import CoreGraphics
import XCTest
@testable import TarmacKit

/// Zooming about a point and panning by a wheel's travel, as viewport changes.
final class BoardTransformTests: XCTestCase {
    private let viewportCenter = CGPoint(x: 400, y: 300)
    private let limits: ClosedRange<CGFloat> = 0.1...3

    private func zoomed(_ viewport: BoardViewport, by factor: CGFloat, about anchor: CGPoint) -> BoardViewport {
        BoardTransform.zoomed(viewport, by: factor, about: anchor, viewportCenter: viewportCenter, limits: limits)
    }

    // MARK: - Zoom

    func testTheZoomIsHeldToItsLimits() {
        XCTAssertEqual(BoardTransform.clampedZoom(0.05, limits: limits), 0.1)
        XCTAssertEqual(BoardTransform.clampedZoom(5, limits: limits), 3)
        XCTAssertEqual(BoardTransform.clampedZoom(1.25, limits: limits), 1.25)
    }

    func testZoomingAboutAPointKeepsTheWorldUnderItWhereItIs() {
        let before = BoardViewport(zoom: 1, cx: 100, cy: 50)
        let anchor = CGPoint(x: 600, y: 400)
        let after = zoomed(before, by: 2, about: anchor)
        XCTAssertEqual(after, BoardViewport(zoom: 2, cx: 200, cy: 100))

        let world = BoardTransform.viewToWorld(
            anchor, zoom: before.zoom, center: CGPoint(x: before.cx, y: before.cy), viewportCenter: viewportCenter
        )
        XCTAssertEqual(
            BoardTransform.worldToView(
                world, zoom: after.zoom, center: CGPoint(x: after.cx, y: after.cy), viewportCenter: viewportCenter
            ),
            anchor
        )
    }

    func testZoomingAboutTheViewportCenterLeavesTheCenterAlone() {
        XCTAssertEqual(
            zoomed(BoardViewport(zoom: 1, cx: 100, cy: 50), by: 0.5, about: viewportCenter),
            BoardViewport(zoom: 0.5, cx: 100, cy: 50)
        )
    }

    /// The center follows the zoom actually reached, not the one asked for.
    func testAZoomCutShortByALimitStillKeepsTheAnchorInPlace() {
        XCTAssertEqual(
            zoomed(BoardViewport(zoom: 2, cx: 0, cy: 0), by: 2, about: CGPoint(x: 460, y: 300)),
            BoardViewport(zoom: 3, cx: 10, cy: 0)
        )
        XCTAssertEqual(
            zoomed(BoardViewport(zoom: 0.2, cx: 0, cy: 0), by: 0.1, about: CGPoint(x: 400, y: 320)),
            BoardViewport(zoom: 0.1, cx: 0, cy: -100)
        )
    }

    func testAtALimitAFurtherZoomMovesNothing() {
        let atMax = BoardViewport(zoom: 3, cx: 10.3, cy: -7.7)
        XCTAssertEqual(zoomed(atMax, by: 1.5, about: CGPoint(x: 13, y: 577)), atMax)
        let atMin = BoardViewport(zoom: 0.1, cx: 10.3, cy: -7.7)
        XCTAssertEqual(zoomed(atMin, by: 0.5, about: CGPoint(x: 13, y: 577)), atMin)
    }

    // MARK: - Pan

    /// The content follows the wheel, so the viewport's center goes the other
    /// way — by the travel in world units.
    func testAPanMovesTheCenterAgainstTheTravelDividedByTheZoom() {
        XCTAssertEqual(
            BoardTransform.panned(BoardViewport(zoom: 2, cx: 100, cy: 50), by: CGVector(dx: 20, dy: -10)),
            BoardViewport(zoom: 2, cx: 90, cy: 55)
        )
    }

    func testAPanLeavesTheZoomAlone() {
        XCTAssertEqual(
            BoardTransform.panned(BoardViewport(zoom: 0.5, cx: 0, cy: 0), by: CGVector(dx: 8, dy: 8)),
            BoardViewport(zoom: 0.5, cx: -16, cy: -16)
        )
    }
}
