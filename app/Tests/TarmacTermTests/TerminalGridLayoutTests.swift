import XCTest
@testable import TarmacTerm

final class TerminalGridLayoutTests: XCTestCase {
    private let cell = CGSize(width: 10, height: 20)
    private let padding = TerminalPadding(top: 2, left: 10, bottom: 16, right: 10)

    private func layout(_ width: CGFloat, _ height: CGFloat) -> TerminalGridLayout? {
        TerminalGridLayout(bounds: CGSize(width: width, height: height), cell: cell, padding: padding)
    }

    func testGridIsTheWholeCellsTheContentBoxHolds() throws {
        let layout = try XCTUnwrap(layout(10 + 80 * 10 + 10, 2 + 24 * 20 + 16))
        XCTAssertEqual(layout.cols, 80)
        XCTAssertEqual(layout.rows, 24)
    }

    /// A zoomed card reads its bounds back through a frame-to-bounds scale, so
    /// a 470pt width arrives as 469.99999999999994; a box that holds exactly N
    /// cells must still hold N, or zooming would resize the PTY.
    func testAWholeCellLostToFloatNoiseIsStillCounted() throws {
        let exact = try XCTUnwrap(layout(470, 498))
        let noisy = try XCTUnwrap(layout(469.99999999999994, 497.99999999999994))
        XCTAssertEqual(exact.cols, 45)
        XCTAssertEqual(noisy.cols, 45)
        XCTAssertEqual(noisy.rows, exact.rows)
    }

    func testPartialCellsAreNotCounted() throws {
        let layout = try XCTUnwrap(layout(10 + 80 * 10 + 9 + 10, 2 + 24 * 20 + 19 + 16))
        XCTAssertEqual(layout.cols, 80)
        XCTAssertEqual(layout.rows, 24)
    }

    func testGridIsBottomAnchoredSoTheRemainderSitsAboveTheFirstRow() throws {
        let layout = try XCTUnwrap(layout(820, 2 + 24 * 20 + 7 + 16))
        XCTAssertEqual(layout.origin, CGPoint(x: 10, y: 9))
        XCTAssertEqual(layout.gridSize, CGSize(width: 800, height: 480))
    }

    func testABoxTooSmallForOneCellHasNoGrid() {
        XCTAssertNil(layout(25, 300))
        XCTAssertNil(layout(300, 30))
        XCTAssertNil(layout(0, 0))
    }

    func testCellRectsAreInViewCoordinates() throws {
        let layout = try XCTUnwrap(layout(820, 498))
        XCTAssertEqual(layout.rect(col: 2, row: 1, span: 3), CGRect(x: 30, y: 22, width: 30, height: 20))
        XCTAssertEqual(layout.rowRect(1), CGRect(x: 10, y: 22, width: 800, height: 20))
    }

    func testSurfacePointIsRelativeToTheGrid() throws {
        let layout = try XCTUnwrap(layout(820, 498))
        XCTAssertEqual(layout.surfacePoint(CGPoint(x: 35, y: 22)), SurfacePoint(x: 25, y: 20))
    }

    func testSurfaceGeometryDescribesTheGrid() throws {
        let layout = try XCTUnwrap(layout(820, 498))
        XCTAssertEqual(layout.surface, SurfaceGeometry(width: 800, height: 480, cellWidth: 10, cellHeight: 20))
    }
}
