import CoreGraphics
import XCTest
@testable import TarmacKit

/// Spec 2609.0011 (#130): the terminal grid a card's box can actually hold.
/// Rows and columns come from the content box — the card's box less its padding
/// and scrollbar — never from the padding box, whose surplus row would fall out of
/// the card.
final class TermGridTests: XCTestCase {
    /// The live card's numbers: padding 2/10/16 (18 vertical, 20 horizontal), the
    /// 14 pt scrollbar reserve and the measured JetBrains Mono cell.
    private func box(
        boxHeight: CGFloat = 290,
        boxWidth: CGFloat = 720,
        paddingVertical: CGFloat = 18,
        paddingHorizontal: CGFloat = 20,
        scrollbarWidth: CGFloat = 14,
        cellWidth: CGFloat = 9.5,
        cellHeight: CGFloat = 21
    ) -> TermGrid.Box {
        TermGrid.Box(
            boxHeight: boxHeight, boxWidth: boxWidth,
            paddingVertical: paddingVertical, paddingHorizontal: paddingHorizontal,
            scrollbarWidth: scrollbarWidth, cellWidth: cellWidth, cellHeight: cellHeight
        )
    }

    // MARK: - S1 rows come from the content box, not the padding box

    func testS1A290ptBoxWith18ptPaddingAndA21ptCellHolds12Rows() {
        // Measuring the padding box gives floor(290 / 21) = 13, and that 13th row is
        // the one that falls out of the card.
        XCTAssertEqual(TermGrid.propose(box())?.rows, 12)
    }

    func testS1PaddingIsWhatSeparatesTheTwoAnswers() {
        XCTAssertEqual(TermGrid.propose(box(paddingVertical: 0))?.rows, 13)
    }

    // MARK: - S2 cols subtract the horizontal padding and the scrollbar

    func testS2720ptWide20ptPadding14ptScrollbar9_5ptCellIs72Cols() {
        XCTAssertEqual(TermGrid.propose(box())?.cols, 72)
    }

    /// Catches a hard-coded 14 pt reserve: it would answer 72 here too.
    func testS2WithNoScrollbarTheSameBoxHolds73() {
        XCTAssertEqual(TermGrid.propose(box(scrollbarWidth: 0))?.cols, 73)
    }

    func testS2WithNoPaddingAndNoScrollbarItHolds75() {
        XCTAssertEqual(TermGrid.propose(box(paddingHorizontal: 0, scrollbarWidth: 0))?.cols, 75)
    }

    // MARK: - S3 the proposed grid always fits, and is the largest that does

    /// The invariant that makes clipping impossible, over a full cell period. Both
    /// clauses are needed: "fits" alone is satisfied by a constant 1 row, "largest"
    /// alone by ceil().
    func testS3FillsTheContentBoxWithoutExceedingIt() throws {
        for boxHeight in stride(from: CGFloat(300), through: 341, by: 1) {
            let b = box(boxHeight: boxHeight)
            let rows = try XCTUnwrap(TermGrid.propose(b)?.rows)
            let content = b.boxHeight - b.paddingVertical
            XCTAssertLessThanOrEqual(CGFloat(rows) * b.cellHeight, content, "boxHeight \(boxHeight)")
            XCTAssertGreaterThan(CGFloat(rows + 1) * b.cellHeight, content, "boxHeight \(boxHeight)")
        }
    }

    // MARK: - S4 an exact multiple of the cell height proposes no extra row

    func testS4ContentOfExactly14CellsHolds14RowsNot15() throws {
        // boxHeight − paddingVertical = 294 = 14 × 21: the height that clipped worst
        // before the fix, where the padding-box answer ends 2 pt past the box.
        let rows = try XCTUnwrap(TermGrid.propose(box(boxHeight: 312))?.rows)
        XCTAssertEqual(rows, 14)
        XCTAssertEqual(rows * 21, 294)
    }

    // MARK: - S5 a collapsed box still yields a usable grid

    func testS5ABoxSmallerThanOneCellFloorsAt2ColsBy1Row() {
        XCTAssertEqual(TermGrid.propose(box(boxHeight: 30, boxWidth: 40)), TermGrid.Grid(cols: 2, rows: 1))
    }

    func testS5PaddingLargerThanTheBoxDoesNotGoNegative() {
        XCTAssertEqual(TermGrid.propose(box(boxHeight: 10, boxWidth: 10)), TermGrid.Grid(cols: 2, rows: 1))
    }

    func testAnAbsurdlyLargeBoxSaturatesInsteadOfTrapping() {
        XCTAssertEqual(TermGrid.propose(box(boxWidth: 1e300, cellWidth: 1))?.cols, .max)
    }

    // MARK: - S9 unusable cell metrics propose nothing

    func testS9AZeroCellHeightReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(cellHeight: 0)))
    }

    func testS9AZeroCellWidthReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(cellWidth: 0)))
    }

    /// `> 0` is false for NaN, but a guard written as `!(v <= 0)` would let it
    /// through and reach the PTY resize.
    func testS9ANaNCellHeightReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(cellHeight: .nan)))
    }

    /// Asserted on its own axis: a guard that only checks the height passes the other.
    func testS9ANaNCellWidthReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(cellWidth: .nan)))
    }

    func testANegativeCellMetricReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(cellHeight: -21)))
        XCTAssertNil(TermGrid.propose(box(cellWidth: -9.5)))
    }

    // MARK: - S10 an unmeasurable box proposes nothing

    func testS10AHiddenBoardBoxOfZeroByZeroReturnsNilRatherThan2By1() {
        XCTAssertNil(TermGrid.propose(box(boxHeight: 0, boxWidth: 0)))
    }

    func testS10AZeroHeightAloneReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(boxHeight: 0)))
    }

    func testS10AZeroWidthAloneReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(boxWidth: 0)))
    }

    func testS10AnInfiniteHeightReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(boxHeight: .infinity)))
    }

    func testS10AnInfiniteWidthReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(boxWidth: .infinity)))
    }

    // MARK: - S10a non-finite padding proposes nothing

    func testS10aANaNVerticalPaddingReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(paddingVertical: .nan)))
    }

    func testS10aANaNHorizontalPaddingReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(paddingHorizontal: .nan)))
    }

    func testS10aANaNScrollbarReserveReturnsNil() {
        XCTAssertNil(TermGrid.propose(box(scrollbarWidth: .nan)))
    }

    func testS10aZeroPaddingIsLegalNotAFailure() {
        XCTAssertNotNil(TermGrid.propose(box(paddingVertical: 0, paddingHorizontal: 0, scrollbarWidth: 0)))
    }
}
