import XCTest
@testable import TarmacKit

/// Spec 2611.0017 D7, D10: a line of runs in its normal form, and its cuts.
final class InlineTextTests: XCTestCase {
    // MARK: - Normal form

    func testQuotedAndPlusJoinPlainRunsSideBySide() {
        XCTAssertEqual(InlineText([b("May"), p(" I?")]).quoted.runs, [p("“"), b("May"), p(" I?”")])
        XCTAssertEqual((InlineText.literal("a ") + InlineText([p("b"), c("c")])).runs, [p("a b"), c("c")])
        XCTAssertEqual(InlineText.literal("").runs, [])
        XCTAssertEqual(InlineText([p(""), b("x"), p("")]).runs, [b("x")])
    }

    // MARK: - Cuts by count

    func testS22PrefixCutsAcrossRunsAndKeepsMarks() {
        let text = InlineText([p("ab"), b("cd"), p("ef")])
        XCTAssertEqual(text.prefix(scalars: 4).runs, [p("ab"), b("c"), p("…")])
        XCTAssertEqual(text.prefix(scalars: 6), text)
        XCTAssertEqual(text.prefix(scalars: 1).runs, [p("…")])
    }

    func testS34ARowCutKeepsGraphemesWhole() {
        let text = InlineText.literal("a👍🏽bc")
        XCTAssertEqual(text.prefix(characters: 3).runs, [p("a👍🏽…")])
        XCTAssertEqual(text.prefix(characters: 4), text)
    }

    // MARK: - Fitting a width (D10)

    /// A fake measure: one unit a character, and two for a code run's box.
    private func units(_ text: InlineText) -> CGFloat {
        CGFloat(text.runs.reduce(0) { $0 + $1.text.count + ($1.mark == .code ? 2 : 0) })
    }

    func testD10ATextThatFitsIsUnchanged() {
        let text = InlineText([p("ab"), c("cdef")])
        XCTAssertEqual(text.prefix(fitting: 8, measure: units), text)
    }

    func testD10TheCutKeepsTheMostCharactersThatFitWithTheEllipsis() {
        let text = InlineText([p("ab"), c("cdef")])
        XCTAssertEqual(text.prefix(fitting: 6, measure: units).runs, [p("ab"), c("c"), p("…")])
        XCTAssertEqual(text.prefix(fitting: 5, measure: units).runs, [p("ab…")])
    }

    func testD10ARoomTooSmallForAnyTextKeepsTheEllipsis() {
        XCTAssertEqual(InlineText.literal("abc").prefix(fitting: 0, measure: units).runs, [p("…")])
    }

    func testD10TheCutKeepsGraphemesWhole() {
        XCTAssertEqual(InlineText.literal("a👍🏽bc").prefix(fitting: 3, measure: units).runs, [p("a👍🏽…")])
        XCTAssertEqual(InlineText.literal("👍🏽👍🏽👍🏽👍🏽").prefix(fitting: 2, measure: units).runs, [p("👍🏽…")])
    }
}
