import XCTest
@testable import TarmacKit

private func p(_ text: String) -> InlineRun { InlineRun(text, .plain) }
private func b(_ text: String) -> InlineRun { InlineRun(text, .bold) }
private func i(_ text: String) -> InlineRun { InlineRun(text, .italic) }
private func c(_ text: String) -> InlineRun { InlineRun(text, .code) }
private func para(_ runs: InlineRun...) -> MarkdownBlock { .paragraph(InlineText(runs)) }
private func item(_ marker: String, _ runs: InlineRun...) -> ListItem { ListItem(marker: marker, text: InlineText(runs)) }

private func blocks(_ text: String) -> [MarkdownBlock] { InlineMarkdown.blocks(text) }

/// Spec 2611.0018 D1: a report's text as blocks, for the inbox preview pane.
final class MarkdownBlocksTests: XCTestCase {
    func testS1TheProtoypesReportIsAParagraphAListAndAParagraph() {
        let text = "Done: **inbox preview** spike on `feat/inbox-preview`.\n"
            + "- added `InboxPreview` to TarmacKit, one rule per block\n"
            + "- 14 new tests pass under `swift test`\n"
            + "- the pill quote now counts *rendered* scalars\n\n"
            + "Left: run `make qa` against a live app, then open the PR."
        XCTAssertEqual(blocks(text), [
            para(p("Done: "), b("inbox preview"), p(" spike on "), c("feat/inbox-preview"), p(".")),
            .list([
                item("•", p("added "), c("InboxPreview"), p(" to TarmacKit, one rule per block")),
                item("•", p("14 new tests pass under "), c("swift test")),
                item("•", p("the pill quote now counts "), i("rendered"), p(" scalars")),
            ]),
            para(p("Left: run "), c("make qa"), p(" against a live app, then open the PR.")),
        ])
    }

    func testS2AnOrderedListKeepsItsNumbersAsWritten() {
        XCTAssertEqual(blocks("Triage:\n1. `swift test` green\n2. `cargo test` green\n12. **one** flaky"), [
            para(p("Triage:")),
            .list([
                item("1.", c("swift test"), p(" green")),
                item("2.", c("cargo test"), p(" green")),
                item("12.", b("one"), p(" flaky")),
            ]),
        ])
    }

    func testS3AHeadingAndACodeBlockKeepTheirLines() {
        XCTAssertEqual(blocks("## Plan\n```\ncargo test  -p tarmacd\nmake qa\n```\nthen ship"), [
            .heading(InlineText([p("Plan")])),
            .code(["cargo test  -p tarmacd", "make qa"]),
            para(p("then ship")),
        ])
    }

    func testAParagraphsLinesJoinWithOneSpace() {
        XCTAssertEqual(blocks("one\n  two   three\nfour"), [para(p("one two three four"))])
    }

    func testS20AnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(blocks("run:\n```\nmake qa"), [para(p("run:")), .code(["make qa"])])
    }

    func testS21OnlyMarkupHasNoBlocks() {
        XCTAssertEqual(blocks("```\n```"), [])
    }

    func testS22AParagraphEndsAList() {
        XCTAssertEqual(blocks("- a\n- b\nnext"), [.list([item("•", p("a")), item("•", p("b"))]), para(p("next"))])
    }

    func testS32AnItemOfTheOtherKindStartsANewList() {
        XCTAssertEqual(blocks("- a\n1. b"), [.list([item("•", p("a"))]), .list([item("1.", p("b"))])])
    }

    func testS27EmptyBlocksKeepTheLineRules() {
        XCTAssertEqual(blocks("- "), [.list([ListItem(marker: "•", text: InlineText([]))])])
        XCTAssertEqual(InlineMarkdown.line("- ").runs, [InlineRun("•", .bullet)])
        XCTAssertEqual(blocks("```\n  \n```"), [])
        XCTAssertEqual(blocks("# \nx"), [para(p("x"))])
    }
}
