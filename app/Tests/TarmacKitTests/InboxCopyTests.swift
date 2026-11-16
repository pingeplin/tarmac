import XCTest
@testable import TarmacKit

/// Spec 2611.0013 S5, S40: what an inbox row says.
final class InboxCopyTests: XCTestCase {
    func testS5ABlockedReportReadsItsTagTitleAndQuote() {
        let report = inboxItem(.report(.blocked), proc: "claude", text: "May I?")
        XCTAssertEqual(InboxCopy.tag(report.kind), "blocked")
        XCTAssertEqual(InboxCopy.title(report), "report · during claude")
        XCTAssertEqual(InboxCopy.quote(report), "“May I?”")
    }

    func testS5ADoneReportWithNoProcOrTextIsTheBareTitleAndNoQuote() {
        let report = inboxItem(.report(.done))
        XCTAssertEqual(InboxCopy.tag(report.kind), "done")
        XCTAssertEqual(InboxCopy.title(report), "report")
        XCTAssertNil(InboxCopy.quote(report))
    }

    func testS5ABellReadsDuringItsProcWithNoQuote() {
        let bell = inboxItem(.bell, proc: "zsh")
        XCTAssertEqual(InboxCopy.tag(bell.kind), "bell")
        XCTAssertEqual(InboxCopy.title(bell), "bell · during zsh")
        XCTAssertNil(InboxCopy.quote(bell))
    }

    func testS5AnExitReadsAsItsToast() {
        XCTAssertEqual(InboxCopy.tag(.exit(code: 3)), "exit")
        XCTAssertEqual(InboxCopy.title(inboxItem(.exit(code: 3), proc: "zsh")), "shell exited · 3")
        XCTAssertEqual(InboxCopy.title(inboxItem(.exit(code: nil))), "killed by signal")
    }

    func testS5AQuoteIsOneLine() {
        XCTAssertEqual(InboxCopy.quote(inboxItem(.report(.blocked), text: "  May\n\tI  run\r\n rm?  ")), "“May I run rm?”")
    }

    func testS5ThePlaceIsBoardTerminalAndFolderUnderHome() {
        let withCwd = inboxItem(.report(.blocked), proc: "zsh", cwd: "/Users/u/w/x")
        XCTAssertEqual(InboxCopy.place(withCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude · ~/w/x")
        let noCwd = inboxItem(.report(.blocked), proc: "zsh")
        XCTAssertEqual(InboxCopy.place(noCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude")
        XCTAssertEqual(InboxCopy.place(noCwd, boardName: nil, cardLabel: "claude", home: "/Users/u"), "board-1 › claude")
    }

    func testThePlaceNamesTheTerminalByItsCardElseItsProcElseShell() {
        let withProc = inboxItem(.bell, proc: "make")
        XCTAssertEqual(InboxCopy.place(withProc, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › make")
        XCTAssertEqual(InboxCopy.place(inboxItem(.bell), boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    func testOnlyAFolderUnderTheHomeFolderStartsWithATilde() {
        let place = { (cwd: String) in
            InboxCopy.place(inboxItem(.bell, cwd: cwd), boardName: "b", cardLabel: "t", home: "/Users/u")
        }
        XCTAssertEqual(place("/Users/u"), "b › t · ~")
        XCTAssertEqual(place("/Users/uu/x"), "b › t · /Users/uu/x")
        XCTAssertEqual(place("/tmp"), "b › t · /tmp")
    }

    func testS40ABellAndAnExitOfABoardNotBuiltReadThin() {
        let bell = inboxItem(.bell)
        XCTAssertEqual(InboxCopy.title(bell), "bell")
        XCTAssertEqual(InboxCopy.place(bell, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
        let exit = inboxItem(.exit(code: 3))
        XCTAssertEqual(InboxCopy.title(exit), "shell exited · 3")
        XCTAssertEqual(InboxCopy.place(exit, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    /// The row's tool tip has the report's whole text, as it was sent.
    func testTheToolTipHasTheWholeText() {
        let report = inboxItem(.report(.blocked), proc: "claude", text: "line one\n  line two")
        XCTAssertEqual(
            InboxCopy.toolTip(report, place: "api › claude"),
            "report · during claude\n“line one\n  line two”\napi › claude"
        )
        XCTAssertEqual(InboxCopy.toolTip(inboxItem(.bell), place: "b › shell"), "bell\nb › shell")
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

    func testS5EveryStringIsEnglish() {
        let items = [
            inboxItem(.report(.blocked), proc: "claude", cwd: "/w", text: "ok"), inboxItem(.report(.done)),
            inboxItem(.bell), inboxItem(.exit(code: 1)), inboxItem(.exit(code: nil)),
        ]
        var strings = [InboxCopy.empty, InboxCopy.footer] + Inbox.Filter.allCases.map(InboxCopy.filterName)
        for i in items {
            strings += [InboxCopy.tag(i.kind), InboxCopy.title(i), InboxCopy.place(i, boardName: nil, cardLabel: nil, home: "/")]
        }
        XCTAssertEqual(InboxCopy.empty, "no items")
        XCTAssertEqual(Inbox.Filter.allCases.map(InboxCopy.filterName), ["all", "reports", "bell", "exit"])
        for string in strings {
            XCTAssertFalse(string.contains("回報") || string.contains("期間"), string)
        }
    }
}
