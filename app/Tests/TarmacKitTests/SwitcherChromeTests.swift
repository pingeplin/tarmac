import XCTest
@testable import TarmacKit

/// S6, S7, S11, S12: the switcher's strings.
final class SwitcherChromeTests: XCTestCase {
    private typealias State = SwitcherKeys.State

    private let rows = BoardSwitcher.rows(
        summaries: [
            BoardSwitcher.BoardSummary(boardID: "board-0", name: "alpha", running: 0, bell: 0, cards: 0, isLive: false),
            BoardSwitcher.BoardSummary(boardID: "board-1", name: nil, running: 0, bell: 0, cards: 0, isLive: false),
        ],
        active: "board-0", filter: ""
    )

    // MARK: query bar (S6)

    func testQueryBarShowsTheFilter() {
        XCTAssertEqual(
            SwitcherChrome.queryBar(State(filter: "inf")),
            SwitcherChrome.QueryBar(label: "⌘K", text: "inf", placeholder: "switch to…")
        )
    }

    func testQueryBarShowsTheRenameBufferWhileRenaming() {
        XCTAssertEqual(
            SwitcherChrome.queryBar(State(filter: "inf", editing: true, editBuffer: "infra")),
            SwitcherChrome.QueryBar(label: "rename:", text: "infra", placeholder: "rename…")
        )
    }

    func testQueryBarKeepsAnEmptyRenameBufferEmpty() {
        XCTAssertEqual(SwitcherChrome.queryBar(State(filter: "inf", editing: true)).text, "")
    }

    func testCaretAndEmptyListText() {
        XCTAssertEqual(SwitcherChrome.caret, "▌")
        XCTAssertEqual(SwitcherChrome.emptyList, "no boards match")
        XCTAssertEqual(SwitcherChrome.activeMark, "●")
    }

    // MARK: row marks (S7)

    func testABoardThatIsNotLiveShowsARing() {
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: false, nowMs: 0), "○")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: false, nowMs: 450), "○")
    }

    func testALiveBoardShowsTheArcOfTheCurrentFifthOfASecond() {
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 0), "◜")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 199), "◜")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 200), "◝")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 400), "◞")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 600), "◟")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 800), "◜")
        XCTAssertEqual(SwitcherChrome.liveGlyph(isLive: true, nowMs: 1_790_000_000_650), "◟")
    }

    func testOrdinalHintOnTheFirstNineRows() {
        XCTAssertEqual(SwitcherChrome.ordinalHint(row: 0), "⌘1")
        XCTAssertEqual(SwitcherChrome.ordinalHint(row: 8), "⌘9")
        XCTAssertNil(SwitcherChrome.ordinalHint(row: 9))
        XCTAssertNil(SwitcherChrome.ordinalHint(row: -1))
    }

    // MARK: footer (S11, S12)

    func testFooterHints() {
        let footer = SwitcherChrome.footer(State(), rows: rows)
        XCTAssertEqual(footer, .hints)
        XCTAssertEqual(footer.runs, [.init("⏎ switch · ⌘N new · ⌘E rename · ⌘⌫ delete")])
    }

    func testFooterWhileRenaming() {
        let footer = SwitcherChrome.footer(State(editing: true, editBuffer: "x"), rows: rows)
        XCTAssertEqual(footer, .renameHints)
        XCTAssertEqual(footer.runs, [.init("⏎ confirm · esc cancel rename")])
    }

    func testFooterNamesTheBoardAnArmedDeleteWouldRemove() {
        let footer = SwitcherChrome.footer(State(selected: 1, confirmingDelete: true), rows: rows)
        XCTAssertEqual(footer, .confirmDelete("board-1"))
        XCTAssertEqual(
            footer.runs,
            [.init("⌘⌫ again to delete "), .init("\"board-1\"", strong: true), .init(" · esc cancel")]
        )
    }

    /// An armed delete with no row under the selection has nothing to name.
    func testFooterFallsBackWhenTheArmedRowIsGone() {
        XCTAssertEqual(SwitcherChrome.footer(State(selected: 5, confirmingDelete: true), rows: rows), .hints)
        XCTAssertEqual(SwitcherChrome.footer(State(confirmingDelete: true), rows: []), .hints)
    }
}
