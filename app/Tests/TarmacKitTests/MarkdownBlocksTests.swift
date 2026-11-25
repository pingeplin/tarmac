import XCTest

@testable import TarmacKit

private func para(_ runs: InlineRun...) -> MarkdownBlock { .paragraph(InlineText(runs)) }
private func item(_ marker: String, _ runs: InlineRun...) -> ListItem {
    ListItem(marker: marker, text: InlineText(runs))
}

private func blocks(_ text: String) -> [MarkdownBlock] { MarkdownBlocks.parse(text) }

/// Spec 2611.0018 D1: a report's text as blocks, for the inbox preview pane.
final class MarkdownBlocksTests: XCTestCase {
    /// "Report text splits into paragraph and list blocks".
    func testThePrototypesReportIsAParagraphAListAndAParagraph() {
        let text =
            "Done: **inbox preview** spike on `feat/inbox-preview`.\n"
            + "- added `InboxPreview` to TarmacKit, one rule per block\n"
            + "- 14 new tests pass under `swift test`\n"
            + "- the pill quote now counts *rendered* scalars\n\n"
            + "Left: run `make qa` against a live app, then open the PR."
        XCTAssertEqual(
            blocks(text),
            [
                para(p("Done: "), b("inbox preview"), p(" spike on "), c("feat/inbox-preview"), p(".")),
                .list([
                    item("•", p("added "), c("InboxPreview"), p(" to TarmacKit, one rule per block")),
                    item("•", p("14 new tests pass under "), c("swift test")),
                    item("•", p("the pill quote now counts "), i("rendered"), p(" scalars")),
                ]),
                para(p("Left: run "), c("make qa"), p(" against a live app, then open the PR.")),
            ])
    }

    /// "Ordered list keeps its numbers".
    func testAnOrderedListKeepsItsNumbersAsWritten() {
        XCTAssertEqual(
            blocks("Triage:\n1. `swift test` green\n2. `cargo test` green\n12. **one** flaky"),
            [
                para(p("Triage:")),
                .list([
                    item("1.", c("swift test"), p(" green")),
                    item("2.", c("cargo test"), p(" green")),
                    item("12.", b("one"), p(" flaky")),
                ]),
            ])
    }

    /// "Heading and code block keep their spacing".
    func testAHeadingAndACodeBlockKeepTheirLines() {
        XCTAssertEqual(
            blocks("## Plan\n```\ncargo test  -p tarmacd\nmake qa\n```\nthen ship"),
            [
                .heading(InlineText([p("Plan")])),
                .code(["cargo test  -p tarmacd", "make qa"]),
                para(p("then ship")),
            ])
    }

    func testAParagraphsLinesJoinWithOneSpace() {
        XCTAssertEqual(blocks("one\n  two   three\nfour"), [para(p("one two three four"))])
    }

    /// "Unclosed fence runs to the end".
    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(blocks("run:\n```\nmake qa"), [para(p("run:")), .code(["make qa"])])
    }

    func testALineThatOpensAndClosesItsBackticksIsAParagraph() {
        XCTAssertEqual(blocks("```make qa``` failed\nsee the log"), [para(c("make qa"), p(" failed see the log"))])
    }

    /// "Text of only fence marks has no blocks".
    func testOnlyMarkupHasNoBlocks() {
        XCTAssertEqual(blocks("```\n```"), [])
    }

    /// "List ends at a paragraph".
    func testAParagraphEndsAList() {
        XCTAssertEqual(blocks("- a\n- b\nnext"), [.list([item("•", p("a")), item("•", p("b"))]), para(p("next"))])
    }

    func testAnItemEndsTheOpenParagraph() {
        XCTAssertEqual(blocks("a\n- b\nc"), [para(p("a")), .list([item("•", p("b"))]), para(p("c"))])
        XCTAssertEqual(InlineMarkdown.line("a\n- b\nc").runs, [p("a "), dot(), p(" b c")])
    }

    /// "Changing list kind starts a new list".
    func testAnItemOfTheOtherKindStartsANewList() {
        XCTAssertEqual(blocks("- a\n1. b"), [.list([item("•", p("a"))]), .list([item("1.", p("b"))])])
        XCTAssertEqual(blocks("1. a\n- b"), [.list([item("1.", p("a"))]), .list([item("•", p("b"))])])
    }

    func testABlankLineAHeadingAndAFenceEachEndAList() {
        XCTAssertEqual(blocks("- a\n\n- b"), [.list([item("•", p("a"))]), .list([item("•", p("b"))])])
        XCTAssertEqual(blocks("- a\n## H"), [.list([item("•", p("a"))]), .heading(InlineText([p("H")]))])
        XCTAssertEqual(blocks("- a\n```\nx\n```"), [.list([item("•", p("a"))]), .code(["x"])])
        XCTAssertEqual(InlineMarkdown.line("- a\n## H").runs, [dot(), p(" a H")])
    }

    func testACodeBlockKeepsTheSpacesAtTheEndsOfItsLines() {
        XCTAssertEqual(blocks("```\n  indented\ntrail  \n```"), [.code(["  indented", "trail  "])])
    }

    /// "Empty blocks match line parsing".
    func testEmptyBlocksKeepTheLineRules() {
        XCTAssertEqual(blocks("- "), [.list([ListItem(marker: "•", text: InlineText([]))])])
        XCTAssertEqual(InlineMarkdown.line("- ").runs, [dot()])
        XCTAssertEqual(blocks("```\n  \n```"), [])
        XCTAssertEqual(blocks("# \nx"), [para(p("x"))])
    }
}
