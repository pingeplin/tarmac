import XCTest
@testable import TarmacKit

/// Spec 2611.0013 S5, S9, S40: what an inbox row and the title-bar button say.
final class InboxCopyTests: XCTestCase {
    private func item(
        _ kind: Inbox.Kind, proc: String? = nil, cwd: String? = nil, text: String? = nil, board: String = "board-1",
        at: UInt64 = 0
    ) -> Inbox.Item {
        Inbox.Item(kind: kind, termID: "T", boardID: board, atMs: at, proc: proc, cwd: cwd, text: text, read: false)
    }

    func testS5ABlockedReportReadsItsTagTitleAndQuote() {
        let report = item(.report(.blocked), proc: "claude", text: "May I?")
        XCTAssertEqual(InboxCopy.tag(report.kind), "blocked")
        XCTAssertEqual(InboxCopy.title(report), "report · during claude")
        XCTAssertEqual(InboxCopy.quote(report), "“May I?”")
    }

    func testS5ADoneReportWithNoProcOrTextIsTheBareTitleAndNoQuote() {
        let report = item(.report(.done))
        XCTAssertEqual(InboxCopy.tag(report.kind), "done")
        XCTAssertEqual(InboxCopy.title(report), "report")
        XCTAssertNil(InboxCopy.quote(report))
    }

    func testS5ABellReadsDuringItsProcWithNoQuote() {
        let bell = item(.bell, proc: "zsh")
        XCTAssertEqual(InboxCopy.tag(bell.kind), "bell")
        XCTAssertEqual(InboxCopy.title(bell), "bell · during zsh")
        XCTAssertNil(InboxCopy.quote(bell))
    }

    func testS5AnExitReadsAsItsToast() {
        XCTAssertEqual(InboxCopy.tag(.exit(code: 3)), "exit")
        XCTAssertEqual(InboxCopy.title(item(.exit(code: 3), proc: "zsh")), "shell exited · 3")
        XCTAssertEqual(InboxCopy.title(item(.exit(code: nil))), "killed by signal")
    }

    func testS5AQuoteIsOneLine() {
        XCTAssertEqual(InboxCopy.quote(item(.report(.blocked), text: "  May\n\tI  run\r\n rm?  ")), "“May I run rm?”")
    }

    func testS5ThePlaceIsBoardTerminalAndFolderUnderHome() {
        let withCwd = item(.report(.blocked), proc: "zsh", cwd: "/Users/u/w/x")
        XCTAssertEqual(InboxCopy.place(withCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude · ~/w/x")
        let noCwd = item(.report(.blocked), proc: "zsh")
        XCTAssertEqual(InboxCopy.place(noCwd, boardName: "api", cardLabel: "claude", home: "/Users/u"), "api › claude")
        XCTAssertEqual(InboxCopy.place(noCwd, boardName: nil, cardLabel: "claude", home: "/Users/u"), "board-1 › claude")
    }

    func testThePlaceNamesTheTerminalByItsCardElseItsProcElseShell() {
        let withProc = item(.bell, proc: "make")
        XCTAssertEqual(InboxCopy.place(withProc, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › make")
        XCTAssertEqual(InboxCopy.place(item(.bell), boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    func testOnlyAFolderUnderTheHomeFolderStartsWithATilde() {
        let place = { (cwd: String) in
            InboxCopy.place(self.item(.bell, cwd: cwd), boardName: "b", cardLabel: "t", home: "/Users/u")
        }
        XCTAssertEqual(place("/Users/u"), "b › t · ~")
        XCTAssertEqual(place("/Users/uu/x"), "b › t · /Users/uu/x")
        XCTAssertEqual(place("/tmp"), "b › t · /tmp")
    }

    func testS40ABellAndAnExitOfABoardNotBuiltReadThin() {
        let bell = item(.bell)
        XCTAssertEqual(InboxCopy.title(bell), "bell")
        XCTAssertEqual(InboxCopy.place(bell, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
        let exit = item(.exit(code: 3))
        XCTAssertEqual(InboxCopy.title(exit), "shell exited · 3")
        XCTAssertEqual(InboxCopy.place(exit, boardName: nil, cardLabel: nil, home: "/Users/u"), "board-1 › shell")
    }

    /// The row's tool tip has the report's whole text, as it was sent.
    func testTheToolTipHasTheWholeText() {
        let report = item(.report(.blocked), proc: "claude", text: "line one\n  line two")
        XCTAssertEqual(
            InboxCopy.toolTip(report, place: "api › claude"),
            "report · during claude\n“line one\n  line two”\napi › claude"
        )
        XCTAssertEqual(InboxCopy.toolTip(item(.bell), place: "b › shell"), "bell\nb › shell")
    }

    func testEachKindHasTheColourOfItsPillSignal() {
        XCTAssertEqual(Inbox.Kind.report(.blocked).signal, .blocked)
        XCTAssertEqual(Inbox.Kind.report(.done).signal, .done)
        XCTAssertEqual(Inbox.Kind.bell.signal, .bell)
        XCTAssertEqual(Inbox.Kind.exit(code: 1).signal, .exit)
    }

    func testTheAgeIsTheReportAge() {
        XCTAssertEqual(InboxCopy.age(item(.bell, at: 1_000), nowMs: 1_000 + 125_000), "2m")
        XCTAssertEqual(InboxCopy.age(item(.bell, at: 9_000), nowMs: 1_000), "<1m")
    }

    func testS5EveryStringIsEnglish() {
        let items = [
            item(.report(.blocked), proc: "claude", cwd: "/w", text: "ok"), item(.report(.done)), item(.bell),
            item(.exit(code: 1)), item(.exit(code: nil)),
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

    func testS9TheBadgeCountsUpTo99() {
        XCTAssertEqual(InboxBadge.text(unread: 0), "inbox")
        XCTAssertEqual(InboxBadge.text(unread: 7), "inbox · 7")
        XCTAssertEqual(InboxBadge.text(unread: 99), "inbox · 99")
        XCTAssertEqual(InboxBadge.text(unread: 100), "inbox · 99+")
    }
}
