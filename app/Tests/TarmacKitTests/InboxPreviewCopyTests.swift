import XCTest
@testable import TarmacKit

/// Spec 2611.0018 D3: what the inbox preview pane says.
final class InboxPreviewCopyTests: XCTestCase {
    func testS5AReportShowsItsRowsHeadAndItsTextAsBlocks() {
        let report = inboxItem(.report(.done), proc: "claude", text: "**ok**", at: 1_000, term: "T1")
        XCTAssertEqual(
            InboxCopy.preview(report, place: "api › claude", nowMs: 1_000 + 125_000),
            InboxPreview(
                id: Inbox.ItemID(termID: "T1", family: .report), kind: .report(.done), tag: "done",
                title: "report · during claude", age: "2m", place: "api › claude",
                body: .blocks([.paragraph(InlineText([InlineRun("ok", .bold)]))])
            )
        )
    }

    func testS6ABellAndAnExitHaveNoText() {
        for kind in [Inbox.Kind.bell, .exit(code: 1)] {
            let preview = InboxCopy.preview(inboxItem(kind), place: "board-1 › shell", nowMs: 0)
            XCTAssertEqual(preview.body, .noText)
            XCTAssertEqual(preview.place, "board-1 › shell")
            XCTAssertEqual(preview.tag, InboxCopy.tag(kind))
        }
    }

    func testS31ABlankTextHasNoText() {
        for text in ["", "  \n ", "\t"] {
            let preview = InboxCopy.preview(inboxItem(.report(.blocked), text: text), place: "p", nowMs: 0)
            XCTAssertEqual(preview.body, .noText, text.debugDescription)
        }
    }

    func testS21TextOfOnlyMarkupShowsAsTyped() {
        let preview = InboxCopy.preview(inboxItem(.report(.done), text: "```\n```"), place: "p", nowMs: 0)
        XCTAssertEqual(preview.body, .blocks([.paragraph(.literal("``` ```"))]))
    }

    func testThePanesWordsAreEnglish() {
        XCTAssertEqual(InboxCopy.go, "go ↵")
        XCTAssertEqual(InboxCopy.noText, "no text")
        XCTAssertEqual(InboxCopy.nothingSelected, "preview · nothing selected")
    }
}
