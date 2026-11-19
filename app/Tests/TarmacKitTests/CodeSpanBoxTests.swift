import XCTest
@testable import TarmacKit

/// Issue #434: the box behind a code span in the inbox preview pane has the
/// look of the inbox row's.
final class CodeSpanBoxTests: XCTestCase {
    /// The system mono face at 11 pt: a one-line text is 14 high, its baseline at 11.
    private let face = CodeSpanBox.Face(baseline: 11, lineHeight: 14)

    func testTheBoxIsTheRowsLineBoxAroundTheTextsBaseline() {
        let glyphs = CGRect(x: 40, y: 17, width: 49.2, height: 17)
        XCTAssertEqual(
            CodeSpanBox.rect(glyphs: glyphs, baseline: 28, face: face), CGRect(x: 37, y: 17, width: 52.2, height: 14)
        )
    }

    /// A face whose line height less its baseline is not the padding.
    func testTheBoxTakesItsHeightAndItsBaselineFromTheFace() {
        let menlo = CodeSpanBox.Face(baseline: 10, lineHeight: 13.5)
        XCTAssertEqual(
            CodeSpanBox.rect(glyphs: CGRect(x: 40, y: 17, width: 49.2, height: 17), baseline: 27, face: menlo),
            CGRect(x: 37, y: 17, width: 52.2, height: 13.5)
        )
    }

    func testTheHeightDoesNotFollowTheLinesOwnHeight() {
        let last = CGRect(x: 40, y: 34, width: 49.2, height: 13)
        XCTAssertEqual(CodeSpanBox.rect(glyphs: last, baseline: 45, face: face).height, 14)
    }

    /// CJK or emoji make a line taller and put its baseline lower.
    func testOnATallerLineTheBoxFollowsTheBaseline() {
        let glyphs = CGRect(x: 40, y: 17, width: 49.2, height: 22)
        XCTAssertEqual(
            CodeSpanBox.rect(glyphs: glyphs, baseline: 17 + 14, face: face), CGRect(x: 37, y: 20, width: 52.2, height: 14)
        )
    }

    /// The box ends where the next character starts, as in the row: the
    /// glyphs' rect has the kern after the span, and the box adds the padding
    /// before it.
    func testTheTextMakesRoomForTheRowsPaddingOnEachSideAndNoMore() {
        XCTAssertEqual(CodeSpanBox.padding, 3)
        XCTAssertEqual(CodeSpanBox.kern, 3)
        let glyphs = CGRect(x: 40, y: 0, width: 46.2 + CodeSpanBox.kern, height: 17)
        let box = CodeSpanBox.rect(glyphs: glyphs, baseline: 11, face: face)
        XCTAssertEqual(box.minX, 40 - 3)
        XCTAssertEqual(box.maxX, glyphs.maxX)
    }

    // MARK: - The kern's character (#436)

    func testTheKernIsOnTheWholeLastCharacterInUTF16Units() {
        XCTAssertEqual(CodeSpanBox.kernRange(endOf: "ab"), 1..<2)
        XCTAssertEqual(CodeSpanBox.kernRange(endOf: "ab😀"), 2..<4)
        XCTAssertEqual(CodeSpanBox.kernRange(endOf: "ae\u{301}"), 1..<3)
        XCTAssertEqual(CodeSpanBox.kernRange(endOf: "a👍🏽"), 1..<5)
        XCTAssertNil(CodeSpanBox.kernRange(endOf: ""))
    }
}
