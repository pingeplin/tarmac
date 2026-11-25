import XCTest

@testable import TarmacKit

/// Spec 2611.0013 "Item copy is English with place line", "Unbuilt board bell and exit make items": what an inbox row says.
final class InboxCopyTests: XCTestCase {
    /// "Item copy is English with place line".
    func testABlockedReportReadsItsTagTitleAndQuote() {
        let report = inboxItem(.report(.blocked), proc: "claude", text: "May I?")
        XCTAssertEqual(InboxCopy.tag(report.kind), "blocked")
        XCTAssertEqual(InboxCopy.title(report), "report · during claude")
        XCTAssertEqual(InboxCopy.quote(report)?.plain, "“May I?”")
    }

    /// "Item copy is English with place line".
    func testADoneReportWithNoProcOrTextIsTheBareTitleAndNoQuote() {
        let report = inboxItem(.report(.done))
        XCTAssertEqual(InboxCopy.tag(report.kind), "done")
        XCTAssertEqual(InboxCopy.title(report), "report")
        XCTAssertNil(InboxCopy.quote(report))
    }

    /// "Item copy is English with place line".
    func testABellReadsDuringItsProcWithNoQuote() {
        let bell = inboxItem(.bell, proc: "zsh")
        XCTAssertEqual(InboxCopy.tag(bell.kind), "bell")
        XCTAssertEqual(InboxCopy.title(bell), "bell · during zsh")
        XCTAssertNil(InboxCopy.quote(bell))
    }

    /// "Item copy is English with place line".
    func testAnExitReadsAsItsToast() {
        XCTAssertEqual(InboxCopy.tag(.exit(code: 3)), "exit")
        XCTAssertEqual(InboxCopy.title(inboxItem(.exit(code: 3), proc: "zsh")), "shell exited · 3")
        XCTAssertEqual(InboxCopy.title(inboxItem(.exit(code: nil))), "killed by signal")
    }

    /// "Item copy is English with place line".
    func testAQuoteIsOneLine() {
        XCTAssertEqual(
            InboxCopy.quote(inboxItem(.report(.blocked), text: "  May\n\tI  run\r\n rm?  "))?.plain, "“May I run rm?”")
    }

    /// "Row quote keeps its marks".
    func testTheRowQuoteRendersInlineMarkdown() {
        XCTAssertEqual(
            InboxCopy.quote(inboxItem(.report(.blocked), text: "**May** I?"))?.runs,
            [p("“"), b("May"), p(" I?”")]
        )
    }

    /// "Text without markdown is unchanged".
    func testARowQuoteWithNoMarkdownReadsAsBefore() {
        for text in S10.texts {
            XCTAssertEqual(
                InboxCopy.quote(inboxItem(.report(.blocked), text: text)), .literal("“\(ChromeText.oneLine(text))”"),
                text
            )
        }
    }

    /// "Blank input gives no runs".
    func testTheQuoteOfAnEmptyReportIsTheQuoteMarks() {
        XCTAssertEqual(InboxCopy.quote(inboxItem(.report(.blocked), text: "")), .literal("“”"))
    }

    /// "Item copy is English with place line".
    func testThePlaceIsBoardTerminalAndFolderUnderHome() {
        let withCwd = inboxItem(.report(.blocked), proc: "zsh", cwd: "/Users/u/w/x")
        XCTAssertEqual(
            InboxCopy.place(withCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude · ~/w/x")
        let noCwd = inboxItem(.report(.blocked), proc: "zsh")
        XCTAssertEqual(InboxCopy.place(noCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude")
        XCTAssertEqual(
            InboxCopy.place(noCwd, boardName: nil, cardLabel: "claude", home: "/Users/u"), "board-1 › claude")
    }

    func testThePlaceNamesTheTerminalByItsCardElseItsProcElseShell() {
        let withProc = inboxItem(.bell, proc: "make")
        XCTAssertEqual(InboxCopy.place(withProc, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › make")
        XCTAssertEqual(
            InboxCopy.place(inboxItem(.bell), boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    func testOnlyAFolderUnderTheHomeFolderStartsWithATilde() {
        let place = { (cwd: String) in
            InboxCopy.place(inboxItem(.bell, cwd: cwd), boardName: "b", cardLabel: "t", home: "/Users/u")
        }
        XCTAssertEqual(place("/Users/u"), "b › t · ~")
        XCTAssertEqual(place("/Users/uu/x"), "b › t · /Users/uu/x")
        XCTAssertEqual(place("/tmp"), "b › t · /tmp")
    }

    /// "Unbuilt board bell and exit make items".
    func testABellAndAnExitOfABoardNotBuiltReadThin() {
        let bell = inboxItem(.bell)
        XCTAssertEqual(InboxCopy.title(bell), "bell")
        XCTAssertEqual(InboxCopy.place(bell, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
        let exit = inboxItem(.exit(code: 3))
        XCTAssertEqual(InboxCopy.title(exit), "shell exited · 3")
        XCTAssertEqual(InboxCopy.place(exit, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    func testEachKindHasTheColourOfItsPillSignal() {
        XCTAssertEqual(Inbox.Kind.report(.blocked).signal, .blocked)
        XCTAssertEqual(Inbox.Kind.report(.done).signal, .done)
        XCTAssertEqual(Inbox.Kind.bell.signal, .bell)
        XCTAssertEqual(Inbox.Kind.exit(code: 1).signal, .exit)
    }

    func testTheAgeIsTheReportAge() {
        XCTAssertEqual(InboxCopy.age(inboxItem(.bell, at: 1_000), nowMs: 1_000 + 125_000), "2m")
        XCTAssertEqual(InboxCopy.age(inboxItem(.bell, at: 9_000), nowMs: 1_000), "<1m")
    }

    func testARowIsTheItemAsItsPlaceTimeAndCopyReadIt() {
        let report = inboxItem(
            .report(.blocked), proc: "claude", cwd: "/Users/u/w", text: "May\nI?", at: 1_000, term: "T1"
        )
        XCTAssertEqual(
            InboxCopy.row(report, boardName: "api", cardLabel: "agent", home: "/Users/u", nowMs: 1_000 + 125_000),
            InboxRow(
                id: Inbox.ItemID(termID: "T1", family: .report), kind: .report(.blocked),
                title: "report · during claude", quote: .literal("“May I?”"), place: "api › agent · ~/w", age: "2m",
                read: false
            )
        )
        let bell = inboxItem(.bell, at: 5_000, read: true)
        XCTAssertEqual(
            InboxCopy.row(bell, boardName: nil, cardLabel: nil, home: "/Users/u", nowMs: 1_000),
            InboxRow(
                id: Inbox.ItemID(termID: "T", family: .bell), kind: .bell, title: "bell", quote: nil,
                place: "board-1 › shell", age: "<1m", read: true
            )
        )
    }

    /// "Item copy is English with place line".
    func testEveryStringIsEnglish() {
        let items = [
            inboxItem(.report(.blocked), proc: "claude", cwd: "/w", text: "ok"), inboxItem(.report(.done)),
            inboxItem(.bell), inboxItem(.exit(code: 1)), inboxItem(.exit(code: nil)),
        ]
        var strings = [InboxCopy.empty, InboxCopy.footer] + Inbox.Filter.allCases.map(InboxCopy.filterName)
        for i in items {
            strings += [
                InboxCopy.tag(i.kind), InboxCopy.title(i),
                InboxCopy.place(i, boardName: nil, cardLabel: nil, home: "/"),
            ]
        }
        XCTAssertEqual(InboxCopy.empty, "no items")
        XCTAssertEqual(Inbox.Filter.allCases.map(InboxCopy.filterName), ["all", "reports", "bell", "exit"])
        for string in strings {
            XCTAssertFalse(string.contains("回報") || string.contains("期間"), string)
        }
    }
}

/// Spec 2611.0018 D3: what the inbox preview pane says.
final class InboxPreviewCopyTests: XCTestCase {
    /// "Report preview copies row title age and place".
    func testAReportShowsItsRowsHeadAndItsTextAsBlocks() {
        let report = inboxItem(.report(.done), proc: "claude", text: "**ok**", at: 1_000, term: "T1")
        XCTAssertEqual(
            InboxCopy.preview(report, place: "api › claude", nowMs: 1_000 + 125_000),
            InboxPreview(
                id: Inbox.ItemID(termID: "T1", family: .report), kind: .report(.done), tag: "done",
                title: "report · during claude", age: "2m", place: "api › claude",
                body: .blocks([.paragraph(InlineText([b("ok")]))])
            )
        )
    }

    /// "Bell and exit previews have no text".
    func testABellAndAnExitHaveNoText() {
        for kind in [Inbox.Kind.bell, .exit(code: 1)] {
            let preview = InboxCopy.preview(inboxItem(kind), place: "board-1 › shell", nowMs: 0)
            XCTAssertEqual(preview.body, .noText)
            XCTAssertEqual(preview.place, "board-1 › shell")
            XCTAssertEqual(preview.tag, InboxCopy.tag(kind))
        }
    }

    /// "Whitespace-only report has no text".
    func testABlankTextHasNoText() {
        for text in ["", "  \n ", "\t"] {
            let preview = InboxCopy.preview(inboxItem(.report(.blocked), text: text), place: "p", nowMs: 0)
            XCTAssertEqual(preview.body, .noText, text.debugDescription)
        }
    }

    /// "Text of only fence marks has no blocks".
    func testTextOfOnlyMarkupShowsAsTyped() {
        let preview = InboxCopy.preview(inboxItem(.report(.done), text: "```\n```"), place: "p", nowMs: 0)
        XCTAssertEqual(preview.body, .blocks([.paragraph(.literal("``` ```"))]))
    }

    func testThePanesWordsAreEnglish() {
        XCTAssertEqual(InboxCopy.go, "go ↵")
        XCTAssertEqual(InboxCopy.noText, "no text")
        XCTAssertEqual(InboxCopy.nothingSelected, "preview · nothing selected")
    }
}
