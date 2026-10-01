import CoreGraphics
import XCTest
@testable import TarmacKit

/// Viewport culling: a card more than one full viewport off-screen is hidden so
/// it stops compositing — but kept alive, so a terminal keeps receiving output.
final class CullTests: XCTestCase {
    private let viewSize = CGSize(width: 1000, height: 600)
    private let origin = CGPoint.zero

    // MARK: - visibleWorldRect

    func testAtZoomOneItSpansTheViewportPlusOneViewportMarginPerSide() {
        let r = Cull.visibleWorldRect(zoom: 1, center: origin, viewSize: viewSize, marginViewports: 1)
        XCTAssertEqual(r.width, 3 * viewSize.width)
        XCTAssertEqual(r.height, 3 * viewSize.height)
        XCTAssertEqual(r.minX, -1.5 * viewSize.width)
        XCTAssertEqual(r.minY, -1.5 * viewSize.height)
    }

    func testZoomBelowOneWidensTheWorldRegion() {
        let r = Cull.visibleWorldRect(zoom: 0.5, center: origin, viewSize: viewSize, marginViewports: 1)
        XCTAssertEqual(r.width, 3 * (viewSize.width / 0.5))
    }

    func testItRecentersOnTheViewportCenter() {
        let r = Cull.visibleWorldRect(zoom: 1, center: CGPoint(x: 200, y: 100), viewSize: viewSize, marginViewports: 0)
        XCTAssertEqual(r.minX, 200 - viewSize.width / 2)
        XCTAssertEqual(r.minY, 100 - viewSize.height / 2)
    }

    func testStaysTheDegenerateRectAtTheCenterForAZeroSizeViewport() {
        let r = Cull.visibleWorldRect(zoom: 1, center: CGPoint(x: 100, y: 100), viewSize: .zero, marginViewports: 1)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 0, height: 0))
    }

    func testTheDefaultMarginIsOneViewport() {
        XCTAssertEqual(Cull.marginViewports, 1)
        XCTAssertEqual(
            Cull.visibleWorldRect(zoom: 1, center: origin, viewSize: viewSize),
            Cull.visibleWorldRect(zoom: 1, center: origin, viewSize: viewSize, marginViewports: 1)
        )
    }

    // MARK: - isCardVisible

    private func visible(
        _ card: CGRect,
        center: CGPoint? = nil,
        viewSize: CGSize? = nil,
        margin: CGFloat = 1
    ) -> Bool {
        Cull.isCardVisible(
            frame: card, zoom: 1, center: center ?? origin,
            viewSize: viewSize ?? self.viewSize, marginViewports: margin
        )
    }

    func testShowsACardAtTheViewportCenter() {
        XCTAssertTrue(visible(CGRect(x: -50, y: -50, width: 100, height: 100)))
    }

    func testKeepsACardWithinTheOneViewportMarginVisibleSoNothingPopsIn() {
        XCTAssertTrue(visible(CGRect(x: 1.5 * viewSize.width - 10, y: 0, width: 100, height: 100)))
    }

    func testHidesACardMoreThanOneViewportOffScreen() {
        XCTAssertFalse(visible(CGRect(x: 2 * viewSize.width, y: 0, width: 100, height: 100)))
    }

    func testAWiderMarginKeepsADistantCardAlive() {
        XCTAssertTrue(visible(CGRect(x: 2 * viewSize.width, y: 0, width: 100, height: 100), margin: 3))
    }

    /// A hidden board measures 0×0; the card whose frame strictly contains the
    /// saved center used to survive the degenerate rect at (cx, cy) (#104).
    func testHidesTheCenterStraddlingCardOnAZeroWidthViewport() {
        let straddler = CGRect(x: 50, y: 50, width: 100, height: 100)
        let hidden = CGPoint(x: 100, y: 100)
        XCTAssertFalse(visible(straddler, center: hidden, viewSize: CGSize(width: 0, height: 600)))
    }

    func testHidesTheCenterStraddlingCardOnAZeroHeightViewport() {
        let straddler = CGRect(x: 50, y: 50, width: 100, height: 100)
        let hidden = CGPoint(x: 100, y: 100)
        XCTAssertFalse(visible(straddler, center: hidden, viewSize: CGSize(width: 1000, height: 0)))
    }

    func testHidesTheCenterStraddlingCardOnAZeroAreaViewport() {
        let straddler = CGRect(x: 50, y: 50, width: 100, height: 100)
        let hidden = CGPoint(x: 100, y: 100)
        XCTAssertFalse(visible(straddler, center: hidden, viewSize: .zero))
    }

    func testAWiderMarginCannotResurrectACardOnAZeroAreaViewport() {
        let straddler = CGRect(x: 50, y: 50, width: 100, height: 100)
        let hidden = CGPoint(x: 100, y: 100)
        XCTAssertFalse(visible(straddler, center: hidden, viewSize: .zero, margin: 3))
    }
}
