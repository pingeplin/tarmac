import CoreGraphics
import XCTest
@testable import TarmacKit

/// Where `tarmac dev key <card> contextmenu` right-clicks (spec 2609.0015,
/// #166): the last cell of the viewport that has a character in it.
final class DevCellPointTests: XCTestCase {
    private typealias Cell = DevCellPoint.Cell

    private let cols = 80
    private let rows = 20
    private let grid = CGRect(x: 100, y: 50, width: 640, height: 320)

    private func viewport(_ lines: [String]) -> [String] {
        (0..<rows).map { $0 < lines.count ? lines[$0] : "" }
    }

    // MARK: - S17 the last written cell

    /// The last non-empty row is index 7 and holds 9 characters, so the target is
    /// cell (8, 7). An off-by-one in either axis lands in a neighbouring cell.
    func testS17TheTargetIsTheLastCharacterOfTheLastWrittenRow() {
        let lines = viewport(["$ echo hi", "", "", "", "", "", "", "123456789"])
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: lines), Cell(col: 8, row: 7))
    }

    func testS17TrailingBlankRowsBelowTheLastWrittenOneAreIgnored() {
        let lines = viewport(["abc", "", "", "", "", "", "", "123456789", "   ", ""])
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: lines), Cell(col: 8, row: 7))
    }

    func testTrailingBlanksOnTheRowAreNotTheTargetAndLeadingOnesStillCount() {
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: ["ab   \t"]), Cell(col: 1, row: 0))
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: ["  ab"]), Cell(col: 3, row: 0))
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: ["a b"]), Cell(col: 2, row: 0))
    }

    /// One grapheme is at least one cell, so the count never runs past the
    /// written cells; counting code units would, for a combining mark or a flag.
    func testACharacterBuiltFromSeveralCodePointsIsOneCell() {
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: ["e\u{301}"]), Cell(col: 0, row: 0))
        XCTAssertEqual(DevCellPoint.lastWrittenCell(in: ["a🇹🇼"]), Cell(col: 1, row: 0))
    }

    func testS17ThePointIsTheExactCellCentre() {
        XCTAssertEqual(
            DevCellPoint.centre(of: Cell(col: 8, row: 7), in: grid, cols: cols, rows: rows),
            CGPoint(x: 100 + 8.5 * (640.0 / 80), y: 50 + 7.5 * (320.0 / 20))
        )
        XCTAssertEqual(
            DevCellPoint.centre(of: Cell(col: 0, row: 0), in: grid, cols: cols, rows: rows),
            CGPoint(x: 104, y: 58)
        )
    }

    /// A grid that is not square in cells: swapping `cols` and `rows` moves both
    /// coordinates.
    func testTheCellSizeComesFromColsAcrossAndRowsDown() {
        XCTAssertEqual(
            DevCellPoint.centre(of: Cell(col: 1, row: 2), in: CGRect(x: 0, y: 0, width: 100, height: 60), cols: 10, rows: 3),
            CGPoint(x: 15, y: 50)
        )
    }

    // MARK: - S18 an empty viewport

    /// A right-click on blank space yields a caret, not a selection, which would
    /// silently downgrade the Range scenario into a second copy of the caret one.
    func testS18AnEmptyViewportHasNoCellToRightClick() {
        XCTAssertNil(DevCellPoint.lastWrittenCell(in: viewport([])))
        XCTAssertNil(DevCellPoint.lastWrittenCell(in: viewport(["   ", "\t"])))
        XCTAssertNil(DevCellPoint.lastWrittenCell(in: []))
    }

    func testS18TheRefusalIsEmptyBufferAndNamesTheCard() {
        let error = DevCellPoint.emptyBuffer(card: "t-1")
        XCTAssertEqual(error.code, .emptyBuffer)
        XCTAssertEqual(error.extra, ["card": "t-1"])
        XCTAssertFalse(error.message.isEmpty)
    }
}
