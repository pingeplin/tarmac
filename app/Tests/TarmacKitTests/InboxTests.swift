import XCTest
@testable import TarmacKit

/// Spec 2611.0013: the inbox store of reports, bells and exits.
final class InboxTests: XCTestCase {
    private func report(
        _ term: String, _ kind: String? = "blocked", text: String? = nil, at: UInt64 = 10, proc: String? = nil,
        read: Bool = false, board: String? = "board-1", cwd: String? = nil
    ) -> TermReportFrame {
        TermReport.frame(.termReport(
            termID: term, kind: kind, text: text, atMs: kind == nil ? nil : at, proc: proc, read: read,
            boardID: kind == nil ? nil : board, cwd: kind == nil ? nil : cwd
        ))!
    }

    private func put(_ inbox: inout Inbox, _ frame: TermReportFrame, fallback: String? = nil) {
        inbox.apply(frame, fallbackBoard: fallback)
    }

    private func bell(_ inbox: inout Inbox, _ term: String, at: UInt64, board: String = "board-1") {
        inbox.bell(termID: term, boardID: board, proc: nil, cwd: nil, nowMs: at)
    }

    private func exit(_ inbox: inout Inbox, _ term: String, code: Int? = 3, at: UInt64, board: String = "board-1") {
        inbox.exit(termID: term, boardID: board, code: code, proc: nil, cwd: nil, nowMs: at)
    }

    private func ids(_ inbox: Inbox, _ filter: Inbox.Filter = .all) -> [Inbox.ItemID] {
        inbox.items(filter).map(\.id)
    }

    private func id(_ term: String, _ family: Inbox.Family) -> Inbox.ItemID {
        Inbox.ItemID(termID: term, family: family)
    }

    func testS1AReportFrameMakesAnUnreadItemWithItsPlace() {
        var inbox = Inbox()
        put(&inbox, report("T", text: "May I?", at: 1000, proc: "claude", cwd: "/w"))
        XCTAssertEqual(inbox.items(.all), [Inbox.Item(
            kind: .report(.blocked), termID: "T", boardID: "board-1", atMs: 1000, proc: "claude", cwd: "/w",
            text: "May I?", read: false
        )])
        XCTAssertEqual(inbox.unreadCount, 1)
    }

    func testS2ANewAtMsReplacesTheItemUnreadAtTheTop() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 10))
        put(&inbox, report("T", at: 10, read: true))
        bell(&inbox, "U", at: 20)
        put(&inbox, report("T", at: 30))
        XCTAssertEqual(ids(inbox), [id("T", .report), id("U", .bell)])
        XCTAssertEqual(inbox.items(.all).first?.atMs, 30)
        XCTAssertEqual(inbox.items(.all).first?.read, false)
    }

    func testS2AReadFrameWithTheSameAtMsKeepsItsPlace() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 20))
        bell(&inbox, "U", at: 20)
        put(&inbox, report("T", at: 20, read: true))
        XCTAssertEqual(ids(inbox), [id("U", .bell), id("T", .report)])
        XCTAssertEqual(inbox.items(.all).count, 2)
        XCTAssertEqual(inbox.items(.reports).first?.read, true)
        XCTAssertEqual(inbox.unreadCount, 1)
    }

    func testS2AFrameWithNoKindRemovesTheReport() {
        var inbox = Inbox()
        put(&inbox, report("T"))
        put(&inbox, report("T", nil))
        XCTAssertEqual(inbox.items(.all), [])
    }

    func testS3NewestFirstAndOnATieThePutLaterFirst() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 10))
        bell(&inbox, "B", at: 30)
        exit(&inbox, "C", at: 20)
        XCTAssertEqual(ids(inbox), [id("B", .bell), id("C", .exit), id("A", .report)])
        bell(&inbox, "D", at: 40)
        bell(&inbox, "E", at: 40)
        XCTAssertEqual(ids(inbox).prefix(2), [id("E", .bell), id("D", .bell)])
    }

    func testS4EachFilterKeepsItsKinds() {
        var inbox = Inbox()
        put(&inbox, report("A", "blocked", at: 1))
        put(&inbox, report("B", "done", at: 2))
        bell(&inbox, "C", at: 3)
        exit(&inbox, "D", at: 4)
        XCTAssertEqual(ids(inbox, .reports), [id("B", .report), id("A", .report)])
        XCTAssertEqual(ids(inbox, .bell), [id("C", .bell)])
        XCTAssertEqual(ids(inbox, .exit), [id("D", .exit)])
        XCTAssertEqual(ids(inbox, .all).count, 4)
    }

    func testS9TheUnreadCountIsEveryUnreadItem() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 1))
        put(&inbox, report("B", at: 2, read: true))
        bell(&inbox, "C", at: 3)
        bell(&inbox, "D", at: 4)
        inbox.touch(termID: "D")
        XCTAssertEqual(inbox.unreadCount, 2)
    }

    func testS16OneBellItemPerTerminalUnreadAgainAfterATouch() {
        var inbox = Inbox()
        bell(&inbox, "T", at: 10)
        inbox.touch(termID: "T")
        bell(&inbox, "T", at: 20)
        XCTAssertEqual(inbox.items(.bell).map(\.atMs), [20])
        XCTAssertEqual(inbox.items(.bell).first?.read, false)
    }

    func testS17ATouchMarksTheBellAndExitReadAndNotTheReport() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1))
        bell(&inbox, "T", at: 2)
        exit(&inbox, "U", at: 3)
        bell(&inbox, "U", at: 4)
        inbox.touch(termID: "T")
        inbox.touch(termID: "U")
        let read = Dictionary(uniqueKeysWithValues: inbox.items(.all).map { ($0.id, $0.read) })
        XCTAssertEqual(read, [id("T", .report): false, id("T", .bell): true, id("U", .exit): true, id("U", .bell): true])
    }

    func testS17NoOtherOperationMarksABellOrAnExitRead() {
        var inbox = Inbox()
        bell(&inbox, "T", at: 1)
        exit(&inbox, "U", at: 2)
        put(&inbox, report("T", at: 3, read: true))
        put(&inbox, report("U", at: 4, read: true))
        exit(&inbox, "T", at: 5)
        bell(&inbox, "U", at: 6)
        inbox.lostConnection()
        inbox.boardBuilt(boardID: "board-1", cards: ["T", "U"], successors: [:])
        XCTAssertEqual(inbox.items(.bell).map(\.read) + inbox.items(.exit).map(\.read), [false, false, false, false])
    }

    func testS18AnExitEndsTheReportKeepsTheBellAndAddsAnUnreadItem() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1, board: "board-0"))
        bell(&inbox, "T", at: 2, board: "board-0")
        inbox.exit(termID: "T", boardID: "board-0", code: 3, proc: "zsh", cwd: "/w", nowMs: 5)
        XCTAssertEqual(ids(inbox), [id("T", .exit), id("T", .bell)])
        XCTAssertEqual(inbox.items(.exit), [Inbox.Item(
            kind: .exit(code: 3), termID: "T", boardID: "board-0", atMs: 5, proc: "zsh", cwd: "/w", text: nil,
            read: false
        )])
    }

    func testS18AnExitOnATerminalWithNoItemKeepsItsBoardProcAndFolder() {
        var inbox = Inbox()
        inbox.exit(termID: "U", boardID: "board-1", code: 3, proc: "make", cwd: "/w/x", nowMs: 5)
        let item = inbox.items(.all).first
        XCTAssertEqual(item?.boardID, "board-1")
        XCTAssertEqual(item?.proc, "make")
        XCTAssertEqual(item?.cwd, "/w/x")
    }

    func testS18ASignalIsAnExitItemAndACleanExitIsNone() {
        var inbox = Inbox()
        exit(&inbox, "T", code: nil, at: 1)
        XCTAssertEqual(inbox.items(.exit).map(\.kind), [.exit(code: nil)])
        put(&inbox, report("U", at: 2))
        exit(&inbox, "U", code: 0, at: 3)
        XCTAssertEqual(ids(inbox), [id("T", .exit)])
    }

    func testS39ACleanExitOnABoardNotBuiltRemovesItsReport() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1, board: "board-1"))
        exit(&inbox, "T", code: 0, at: 2, board: "board-1")
        XCTAssertEqual(inbox.items(.all), [])
    }

    func testS39ReportEndedRemovesTheReportAndKeepsTheBell() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1))
        bell(&inbox, "T", at: 2)
        inbox.reportEnded(termID: "T")
        XCTAssertEqual(ids(inbox), [id("T", .bell)])
    }

    func testS39KeepBoardsRemovesOnlyTheItemsOfBoardsNotKept() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 1, board: "board-0"))
        bell(&inbox, "B", at: 2, board: "board-1")
        put(&inbox, report("C", at: 3, board: "board-1"))
        exit(&inbox, "D", at: 4, board: "board-2")
        inbox.keepBoards(["board-0", "board-2"])
        XCTAssertEqual(ids(inbox), [id("D", .exit), id("A", .report)])
    }

    func testS19ADismissedReportStaysHiddenForItsAtMsAndShowsAgainForANewOne() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 10))
        bell(&inbox, "T", at: 11)
        inbox.dismiss(id("T", .report))
        XCTAssertEqual(ids(inbox), [id("T", .bell)])
        XCTAssertEqual(inbox.unreadCount, 1)
        put(&inbox, report("T", at: 10))
        XCTAssertEqual(ids(inbox), [id("T", .bell)])
        put(&inbox, report("T", at: 12))
        XCTAssertEqual(ids(inbox), [id("T", .report), id("T", .bell)])
        XCTAssertEqual(inbox.items(.reports).first?.read, false)
    }

    func testS19ClearReadHidesTheReadItemsTheFilterShows() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 1, read: true))
        bell(&inbox, "B", at: 2)
        bell(&inbox, "C", at: 3)
        inbox.touch(termID: "B")
        inbox.clearRead(.bell)
        XCTAssertEqual(ids(inbox), [id("C", .bell), id("A", .report)])
        inbox.clearRead(.all)
        XCTAssertEqual(ids(inbox), [id("C", .bell)])
    }

    func testS20ALostConnectionDropsTheReportsAndKeepsTheRestAndTheDismissals() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 1))
        put(&inbox, report("B", at: 2))
        bell(&inbox, "C", at: 3)
        exit(&inbox, "D", at: 4)
        inbox.dismiss(id("A", .report))
        inbox.lostConnection()
        XCTAssertEqual(ids(inbox), [id("D", .exit), id("C", .bell)])
        put(&inbox, report("A", at: 1))
        put(&inbox, report("B", at: 2))
        XCTAssertEqual(ids(inbox), [id("D", .exit), id("C", .bell), id("B", .report)])
    }

    func testS21ACardOrABoardGoesWithItsItems() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1))
        bell(&inbox, "T", at: 2)
        exit(&inbox, "T", at: 3)
        bell(&inbox, "U", at: 4, board: "board-0")
        inbox.removeTerm(termID: "T")
        XCTAssertEqual(ids(inbox), [id("U", .bell)])
        put(&inbox, report("V", at: 5, board: "board-1"))
        inbox.removeBoard(boardID: "board-1")
        XCTAssertEqual(ids(inbox), [id("U", .bell)])
    }

    func testS22OverTheCapTheOldestReadItemGoesFirst() {
        var inbox = Inbox()
        bell(&inbox, "t0", at: 0)
        bell(&inbox, "t1", at: 1)
        bell(&inbox, "t2", at: 2)
        inbox.touch(termID: "t2")
        for n in 3..<Inbox.maxItems { bell(&inbox, "t\(n)", at: UInt64(n)) }
        XCTAssertEqual(inbox.items(.all).count, 200)
        bell(&inbox, "new", at: 1000)
        let terms = Set(inbox.items(.all).map(\.termID))
        XCTAssertEqual(terms.count, 200)
        XCTAssertFalse(terms.contains("t2"))
        XCTAssertTrue(terms.isSuperset(of: ["t0", "t1", "new"]))
    }

    func testS22WithEveryItemUnreadTheOldestGoes() {
        var inbox = Inbox()
        for n in 0..<Inbox.maxItems { bell(&inbox, "t\(n)", at: UInt64(n)) }
        bell(&inbox, "new", at: 1000)
        let terms = Set(inbox.items(.all).map(\.termID))
        XCTAssertEqual(terms.count, 200)
        XCTAssertFalse(terms.contains("t0"))
        XCTAssertTrue(terms.isSuperset(of: ["t1", "new"]))
    }

    func testS23AFrameWithNoBoardUsesTheFallbackElseMakesNoItem() {
        var inbox = Inbox()
        put(&inbox, report("T", at: 1, board: nil), fallback: "board-0")
        XCTAssertEqual(inbox.items(.all).map(\.boardID), ["board-0"])
        put(&inbox, report("U", at: 2, board: nil), fallback: nil)
        XCTAssertEqual(ids(inbox), [id("T", .report)])
    }

    func testS40ABellAndAnExitOfABoardNotBuiltMakeThinItems() {
        var inbox = Inbox()
        inbox.bell(termID: "T", boardID: "board-1", proc: nil, cwd: nil, nowMs: 1)
        inbox.exit(termID: "U", boardID: "board-1", code: 3, proc: nil, cwd: nil, nowMs: 2)
        XCTAssertEqual(inbox.items(.all).map(\.boardID), ["board-1", "board-1"])
        XCTAssertEqual(inbox.items(.all).map(\.proc), [nil, nil])
    }

    func testS41TheFirstBuildKeepsRowsWithACardOrASuccessorAndDropsTheRest() {
        var inbox = Inbox()
        bell(&inbox, "T", at: 1)
        exit(&inbox, "U", at: 2)
        exit(&inbox, "W", at: 3)
        bell(&inbox, "X", at: 4, board: "board-2")
        inbox.boardBuilt(boardID: "board-1", cards: ["T", "U2"], successors: ["U": "U2"])
        XCTAssertEqual(ids(inbox), [id("X", .bell), id("U", .exit), id("T", .bell)])
        XCTAssertEqual(inbox.target(termID: "T"), "T")
        XCTAssertEqual(inbox.target(termID: "U"), "U2")
        XCTAssertNil(inbox.target(termID: "W"))
    }

    func testS41AReportItemIsNotDroppedByTheBuild() {
        var inbox = Inbox()
        put(&inbox, report("W", at: 1))
        inbox.boardBuilt(boardID: "board-1", cards: [], successors: [:])
        XCTAssertEqual(ids(inbox), [id("W", .report)])
    }

    func testTheUnreadReportsOfABoardCountOnlyItsUnreadReports() {
        var inbox = Inbox()
        put(&inbox, report("A", at: 1))
        put(&inbox, report("B", "done", at: 2))
        put(&inbox, report("C", at: 3, read: true))
        put(&inbox, report("D", at: 4, board: "board-0"))
        bell(&inbox, "E", at: 5)
        inbox.dismiss(id("B", .report))
        XCTAssertEqual(inbox.unreadReports(board: "board-1"), 1)
        XCTAssertEqual(inbox.unreadReports(board: "board-0"), 1)
        XCTAssertEqual(inbox.unreadReports(board: "board-9"), 0)
    }

    func testExitUnreadIsTheTerminalsUnreadExitItem() {
        var inbox = Inbox()
        exit(&inbox, "T", at: 1)
        bell(&inbox, "U", at: 2)
        XCTAssertTrue(inbox.exitUnread(termID: "T"))
        XCTAssertFalse(inbox.exitUnread(termID: "U"))
        inbox.touch(termID: "T")
        XCTAssertFalse(inbox.exitUnread(termID: "T"))
    }

    func testTheFiltersCycleInOrderAndWrap() {
        XCTAssertEqual(Inbox.Filter.all.next, .reports)
        XCTAssertEqual(Inbox.Filter.reports.next, .bell)
        XCTAssertEqual(Inbox.Filter.bell.next, .exit)
        XCTAssertEqual(Inbox.Filter.exit.next, .all)
        XCTAssertEqual(Inbox.Filter.all.previous, .exit)
        XCTAssertEqual(Inbox.Filter.bell.previous, .reports)
    }
}
