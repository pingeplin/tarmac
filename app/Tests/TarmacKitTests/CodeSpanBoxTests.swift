import XCTest
@testable import TarmacKit

/// Issue #432: the box behind a code span in the inbox preview pane.
final class CodeSpanBoxTests: XCTestCase {
    private let glyphs = CGRect(x: 40, y: 17, width: 46, height: 17)

    func testTheBoxLeavesOutTheLineSpacingBelowALine() {
        XCTAssertEqual(
            CodeSpanBox.rect(glyphs: glyphs, lineSpacing: 4, lastLineOfText: false),
            CGRect(x: 36.5, y: 17, width: 48, height: 13)
        )
    }

    /// TextKit adds no line spacing below the last line of the text.
    func testTheLastLineOfTheTextHasNoLineSpacingToLeaveOut() {
        let last = CGRect(x: 40, y: 34, width: 46, height: 13)
        XCTAssertEqual(
            CodeSpanBox.rect(glyphs: last, lineSpacing: 4, lastLineOfText: true),
            CGRect(x: 36.5, y: 34, width: 48, height: 13)
        )
    }

    func testTheKernThatMakesRoomIsTwiceTheInsetLessTheWidthTheBoxAdds() {
        XCTAssertEqual(CodeSpanBox.inset, 3.5)
        XCTAssertEqual(CodeSpanBox.kern, 5)
    }
}
