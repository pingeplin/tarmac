import CoreGraphics
import XCTest
@testable import TarmacKit

/// Card-resize geometry: edge handles resize one axis, corner handles both; the
/// top/left edges move the origin while the opposite edge stays pinned, and the
/// minimum size clamps each active axis.
final class CardResizeTests: XCTestCase {
    private let start = CGRect(x: 0, y: 0, width: 200, height: 200)

    private func resized(
        _ handle: CardResize.Handle,
        _ dx: CGFloat,
        _ dy: CGFloat,
        from frame: CGRect? = nil
    ) -> CGRect {
        CardResize.frame(from: frame ?? start, dragging: handle, by: CGVector(dx: dx, dy: dy))
    }

    // MARK: - Edge handles

    func testRightEdgeGrowsWidthRightwardLeavingTheRestUntouched() {
        XCTAssertEqual(resized(.right, 50, 99), CGRect(x: 0, y: 0, width: 250, height: 200))
    }

    func testLeftEdgeShiftsTheOriginLeftAndGrowsWidth() {
        XCTAssertEqual(resized(.left, -50, 99), CGRect(x: -50, y: 0, width: 250, height: 200))
    }

    func testBottomEdgeGrowsHeightDownward() {
        XCTAssertEqual(resized(.bottom, 99, 50), CGRect(x: 0, y: 0, width: 200, height: 250))
    }

    func testTopEdgeShiftsTheOriginUpAndGrowsHeight() {
        XCTAssertEqual(resized(.top, 99, -50), CGRect(x: 0, y: -50, width: 200, height: 250))
    }

    // MARK: - Corner handles

    func testBottomRightGrowsBothAxesWithTheOriginUnchanged() {
        XCTAssertEqual(
            resized(.bottomRight, 50, 30, from: CGRect(x: 0, y: 0, width: 200, height: 100)),
            CGRect(x: 0, y: 0, width: 250, height: 130)
        )
    }

    func testTopLeftShiftsTheOriginOnBothAxesWithTheOppositeEdgesPinned() {
        XCTAssertEqual(
            resized(.topLeft, -50, -20, from: CGRect(x: 100, y: 100, width: 200, height: 100)),
            CGRect(x: 50, y: 80, width: 250, height: 120)
        )
    }

    func testTopRightShiftsYGrowsWidthRightwardAndKeepsX() {
        XCTAssertEqual(resized(.topRight, 50, -30), CGRect(x: 0, y: -30, width: 250, height: 230))
    }

    func testBottomLeftShiftsXGrowsHeightDownwardAndKeepsY() {
        XCTAssertEqual(resized(.bottomLeft, -30, 50), CGRect(x: -30, y: 0, width: 230, height: 250))
    }

    // MARK: - Per-axis minimum clamp

    func testTopPastTheMinimumHeightClampsAndPinsTheBottomEdge() {
        XCTAssertEqual(
            resized(.top, 99, 150),
            CGRect(x: 0, y: 200 - CardResize.minHeight, width: 200, height: CardResize.minHeight)
        )
    }

    func testLeftPastTheMinimumWidthClampsAndPinsTheRightEdge() {
        XCTAssertEqual(
            resized(.left, 100, 99),
            CGRect(x: 200 - CardResize.minWidth, y: 0, width: CardResize.minWidth, height: 200)
        )
    }

    func testRightPastTheMinimumWidthClampsWithTheOriginUnchanged() {
        XCTAssertEqual(resized(.right, -100, 99), CGRect(x: 0, y: 0, width: CardResize.minWidth, height: 200))
    }

    func testBottomRightClampsBothAxesAtOnceWithTheOriginUnchanged() {
        XCTAssertEqual(
            resized(.bottomRight, -300, -300, from: CGRect(x: 0, y: 0, width: 200, height: 100)),
            CGRect(x: 0, y: 0, width: CardResize.minWidth, height: CardResize.minHeight)
        )
    }

    func testTopLeftClampsBothAxesAndPinsTheRightAndBottomEdges() {
        XCTAssertEqual(
            resized(.topLeft, 300, 300, from: CGRect(x: 100, y: 100, width: 200, height: 100)),
            CGRect(x: 140, y: 110, width: CardResize.minWidth, height: CardResize.minHeight)
        )
    }

    /// The width axis clamps independently while the height grows freely; the
    /// right edge stays pinned at 300, so x = 300 − minWidth.
    func testTopLeftClampsWidthWhileHeightGrowsFreely() {
        XCTAssertEqual(
            resized(.topLeft, 300, -20, from: CGRect(x: 100, y: 100, width: 200, height: 100)),
            CGRect(x: 140, y: 80, width: CardResize.minWidth, height: 120)
        )
    }

    func testZeroDeltaIsTheIdentityForEdgeAndCornerHandles() {
        XCTAssertEqual(resized(.right, 0, 0), start)
        XCTAssertEqual(resized(.topLeft, 0, 0), start)
    }

    func testAnExplicitMinimumSizeOverridesTheDefault() {
        XCTAssertEqual(
            CardResize.frame(
                from: start, dragging: .bottomRight, by: CGVector(dx: -300, dy: -300),
                minSize: CGSize(width: 50, height: 40)
            ),
            CGRect(x: 0, y: 0, width: 50, height: 40)
        )
    }

    func testTheDefaultMinimumSizeIs160By90() {
        XCTAssertEqual(CardResize.minWidth, 160)
        XCTAssertEqual(CardResize.minHeight, 90)
    }
}
