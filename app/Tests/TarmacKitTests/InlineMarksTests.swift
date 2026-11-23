import XCTest

@testable import TarmacKit

/// Spec 2611.0017 D3–D4: the inline marks of one line of source, read without
/// the block parser in front of it. The rules as a report shows them are in
/// `InlineMarkdownTests`.
final class InlineMarksTests: XCTestCase {
    private func marks(_ source: String) -> [InlineRun] { InlineMarks.text(source).runs }

    func testAPairOfMarksIsBoldBeforeItIsItalic() {
        XCTAssertEqual(marks("**a** *b*"), [b("a"), p(" "), i("b")])
        XCTAssertEqual(marks("__a__ _b_"), [b("a"), p(" "), i("b")])
    }

    func testEmphasisContentCannotEndWithWhitespace() {
        XCTAssertEqual(marks("*a *"), [p("*a *")])
        XCTAssertEqual(marks("**a **"), [p("**a **")])
    }

    func testAnUnderscoreAfterADotThatFollowsAWordIsInsideTheWord() {
        XCTAssertEqual(marks("x._a_"), [p("x._a_")])
        XCTAssertEqual(marks("._a_"), [p("."), i("a")])
    }

    func testAnUnderscoreBeforeAWordDoesNotCloseAMark() {
        XCTAssertEqual(marks("_a_b"), [p("_a_b")])
        XCTAssertEqual(marks("_a_b_"), [i("a_b")])
    }

    func testALinkNeedsItsParenthesesRightAfterTheBracket() {
        XCTAssertEqual(marks("[a]"), [p("[a]")])
        XCTAssertEqual(marks("x [a]"), [p("x [a]")])
        XCTAssertEqual(marks("[a] (u)"), [p("[a] (u)")])
        XCTAssertEqual(marks("[a](u"), [p("[a](u")])
        XCTAssertEqual(marks("[a](u) b"), [l("a"), p(" b")])
    }

    func testWhitespaceSettlesToOneSpaceInsideAndNoneAtTheEnds() {
        XCTAssertEqual(marks(" \t a \t\n b  "), [p("a b")])
        XCTAssertEqual(marks("  **a   b**  c  "), [b("a b"), p(" c")])
        XCTAssertEqual(marks("  `x`"), [c("x")])
    }

    func testSettlingTrimsTheOuterEndsWhateverTheirMark() {
        XCTAssertEqual(InlineText([b(" a  b "), p("  c "), i(" d ")]).settled.runs, [b("a b "), p(" c "), i(" d")])
    }

    func testASettledEndThatWasOnlyWhitespaceIsDropped() {
        XCTAssertEqual(InlineText([p("  "), b("a"), p("\t")]).settled.runs, [b("a")])
    }
}
