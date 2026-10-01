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

    /// A row of narrow cells, one per character, padded with empty cells the way
    /// the grid holds an unwritten one.
    private func narrow(_ text: String) -> [String] {
        let cells = text.map(String.init)
        return cells + Array(repeating: "", count: max(cols - cells.count, 0))
    }

    private func viewport(_ lines: [String]) -> [[String]] {
        (0..<rows).map { narrow($0 < lines.count ? lines[$0] : "") }
    }

    private func lastWritten(_ cells: [String]) -> Cell? {
        DevCellPoint.lastWrittenCell(in: [cells])
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
        XCTAssertEqual(lastWritten(narrow("ab   \t")), Cell(col: 1, row: 0))
        XCTAssertEqual(lastWritten(narrow("  ab")), Cell(col: 3, row: 0))
        XCTAssertEqual(lastWritten(narrow("a b")), Cell(col: 2, row: 0))
        XCTAssertEqual(lastWritten(["a", "b"]), Cell(col: 1, row: 0))
    }

    /// A wide character holds two cells — itself, then an empty spacer — so every
    /// column after it is one further right than a count of characters says.
    /// Counting characters lands on the blank beside the last word, where a
    /// right-click selects nothing and the verb still answers ok.
    func testAColumnIsAGridCellSoAWideCharacterBeforeTheTargetCountsTwice() {
        XCTAssertEqual(lastWritten(["~", "/", "文", "", " ", "%", " "]), Cell(col: 5, row: 0))
        XCTAssertEqual(lastWritten(["中", "", " ", "x"]), Cell(col: 3, row: 0))
        XCTAssertEqual(lastWritten(["😀", "", " ", "x"]), Cell(col: 3, row: 0))
        XCTAssertEqual(
            lastWritten(["~", "/", "文", "", "件", "", "夹", "", " ", "%", " "]),
            Cell(col: 9, row: 0)
        )
    }

    /// The spacer holds no text of its own: the target is the cell the character
    /// is in, not the half-cell after it.
    func testARowEndingInAWideCharacterTargetsItsOwnCellNotItsSpacer() {
        XCTAssertEqual(lastWritten(["a", "b", "中", ""]), Cell(col: 2, row: 0))
        XCTAssertEqual(lastWritten(["a", "b", "中", "", "", ""]), Cell(col: 2, row: 0))
    }

    /// A cell's text is whatever the grid put in it; a base with a combining mark
    /// or a flag is one cell however many code points it takes.
    func testACellHoldingSeveralCodePointsIsStillOneColumn() {
        XCTAssertEqual(lastWritten(["e\u{301}", "x"]), Cell(col: 1, row: 0))
        XCTAssertEqual(lastWritten(["🇹🇼", "", "a"]), Cell(col: 2, row: 0))
        XCTAssertEqual(lastWritten(["x", "e\u{301}"]), Cell(col: 1, row: 0))
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
        XCTAssertNil(DevCellPoint.lastWrittenCell(in: [[], []]))
        XCTAssertNil(lastWritten(["", " ", "\t", "  "]))
    }

    func testS18TheRefusalIsEmptyBufferAndNamesTheCard() {
        let error = DevCellPoint.emptyBuffer(card: "t-1")
        XCTAssertEqual(error.code, .emptyBuffer)
        XCTAssertEqual(error.extra, ["card": "t-1"])
        XCTAssertFalse(error.message.isEmpty)
    }
}
