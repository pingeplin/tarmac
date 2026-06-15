import XCTest
@testable import TarmacKit

/// M3 P4: the ⌘K switcher view-model — prefix filter, ⌘1..9 ordinal on the
/// *visible* rows, selection clamp, and meta-line formatting.
final class BoardSwitcherTests: XCTestCase {
    private func sum(_ id: String, name: String? = nil, running: Int = 0, bell: Int = 0, cards: Int = 0, isLive: Bool = true) -> BoardSwitcher.BoardSummary {
        BoardSwitcher.BoardSummary(boardID: id, name: name, running: running, bell: bell, cards: cards, isLive: isLive)
    }

    private let three = [
        BoardSwitcher.BoardSummary(boardID: "board-0", name: "infra-week", running: 2, bell: 1, cards: 8, isLive: true),
        BoardSwitcher.BoardSummary(boardID: "board-1", name: "exp-search", running: 1, bell: 0, cards: 3, isLive: true),
        BoardSwitcher.BoardSummary(boardID: "board-2", name: nil, running: 0, bell: 0, cards: 0, isLive: false),
    ]

    // MARK: - liveness() (P5: honest per-board liveness)

    func testVisitedBoardUsesLocalSignalsNotDaemonCount() {
        // A board the app has visited: local card signals are authoritative, so
        // the daemon's count is ignored (no flicker against the local view).
        let r = BoardSwitcher.liveness(visited: true, localRunning: 2, localIsLive: true, daemonRunning: 0)
        XCTAssertEqual(r.running, 2)
        XCTAssertTrue(r.isLive)
    }

    func testVisitedBoardWithNoLocalLiveIsNotLive() {
        let r = BoardSwitcher.liveness(visited: true, localRunning: 0, localIsLive: false, daemonRunning: 5)
        XCTAssertEqual(r.running, 0)
        XCTAssertFalse(r.isLive, "a visited board's own (dead) sessions win over a stale daemon count")
    }

    func testNeverVisitedBoardUsesDaemonRunningForLiveness() {
        // The relaunch case: shells survived, the app hasn't visited the board, so
        // the daemon's live-pty count is the only honest source.
        let r = BoardSwitcher.liveness(visited: false, localRunning: 0, localIsLive: false, daemonRunning: 3)
        XCTAssertEqual(r.running, 3)
        XCTAssertTrue(r.isLive)
    }

    func testNeverVisitedBoardWithZeroDaemonRunningIsFaint() {
        let r = BoardSwitcher.liveness(visited: false, localRunning: 0, localIsLive: false, daemonRunning: 0)
        XCTAssertEqual(r.running, 0)
        XCTAssertFalse(r.isLive)
    }

    func testNeverVisitedBoardWithNilDaemonRunningIsFaint() {
        // A pre-P5 daemon (or no report) → nil → treated as zero live.
        let r = BoardSwitcher.liveness(visited: false, localRunning: 0, localIsLive: false, daemonRunning: nil)
        XCTAssertEqual(r.running, 0)
        XCTAssertFalse(r.isLive)
    }

    // MARK: - rows()

    func testEmptyFilterKeepsAllInOrder() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-1", filter: "")
        XCTAssertEqual(rows.map(\.boardID), ["board-0", "board-1", "board-2"])
    }

    func testActiveFlagMarksTheActiveBoard() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-1", filter: "")
        XCTAssertEqual(rows.map(\.isActive), [false, true, false])
    }

    func testUnnamedBoardFallsBackToSlug() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "")
        XCTAssertEqual(rows[2].display, "board-2")
    }

    func testFilterIsCaseInsensitivePrefixOnDisplay() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "EXP")
        XCTAssertEqual(rows.map(\.boardID), ["board-1"])
    }

    func testFilterMatchesSlugForUnnamedBoards() {
        // "board-2" has no name → its display is the slug, so the slug filters it.
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "board-2")
        XCTAssertEqual(rows.map(\.boardID), ["board-2"])
    }

    func testPrefixDoesNotMatchMidString() {
        // "week" is a substring of "infra-week" but not a prefix → no match.
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "week")
        XCTAssertTrue(rows.isEmpty)
    }

    func testRowCarriesGlyphAndCountInputs() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "infra")
        let r = rows[0]
        XCTAssertTrue(r.isLive)
        XCTAssertEqual(r.running, 2)
        XCTAssertEqual(r.bell, 1)
        XCTAssertEqual(r.cards, 8)
        XCTAssertEqual(r.meta, "2 running · 1 bell · 8 cards")
    }

    // MARK: - boardID(forOrdinal:in:)

    func testOrdinalIsOneBasedOnVisibleRows() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "")
        XCTAssertEqual(BoardSwitcher.boardID(forOrdinal: 1, in: rows), "board-0")
        XCTAssertEqual(BoardSwitcher.boardID(forOrdinal: 3, in: rows), "board-2")
    }

    func testOrdinalAddressesFilteredRowsNotFullList() {
        // After filtering to a single row, ⌘1 must hit that visible row.
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "exp")
        XCTAssertEqual(BoardSwitcher.boardID(forOrdinal: 1, in: rows), "board-1")
        XCTAssertNil(BoardSwitcher.boardID(forOrdinal: 2, in: rows))
    }

    func testOrdinalOutOfRangeIsNil() {
        let rows = BoardSwitcher.rows(summaries: three, active: "board-0", filter: "")
        XCTAssertNil(BoardSwitcher.boardID(forOrdinal: 0, in: rows))
        XCTAssertNil(BoardSwitcher.boardID(forOrdinal: 4, in: rows))
    }

    // MARK: - clampSelection

    func testClampSelectionBounds() {
        XCTAssertEqual(BoardSwitcher.clampSelection(-3, count: 3), 0)
        XCTAssertEqual(BoardSwitcher.clampSelection(1, count: 3), 1)
        XCTAssertEqual(BoardSwitcher.clampSelection(9, count: 3), 2)
        XCTAssertEqual(BoardSwitcher.clampSelection(0, count: 0), 0, "empty list pins to 0")
    }

    // MARK: - meta()

    func testMetaAllSegments() {
        XCTAssertEqual(BoardSwitcher.meta(running: 2, bell: 1, cards: 8), "2 running · 1 bell · 8 cards")
    }

    func testMetaDropsZeroRunningAndBell() {
        XCTAssertEqual(BoardSwitcher.meta(running: 0, bell: 0, cards: 3), "3 cards")
        XCTAssertEqual(BoardSwitcher.meta(running: 1, bell: 0, cards: 3), "1 running · 3 cards")
    }

    func testMetaSingularCard() {
        XCTAssertEqual(BoardSwitcher.meta(running: 0, bell: 0, cards: 1), "1 card")
    }

    func testMetaCardsAlwaysShownEvenAtZero() {
        XCTAssertEqual(BoardSwitcher.meta(running: 0, bell: 0, cards: 0), "0 cards")
    }

    // MARK: - P5.4 rename / delete validation

    func testCanDeleteOnlyWhenMoreThanOne() {
        XCTAssertTrue(BoardSwitcher.canDelete(boardCount: 2))
        XCTAssertFalse(BoardSwitcher.canDelete(boardCount: 1), "the last board can't be deleted")
        XCTAssertFalse(BoardSwitcher.canDelete(boardCount: 0))
    }

    func testSanitizedNameTrimsAndBlanksToEmpty() {
        XCTAssertEqual(BoardSwitcher.sanitizedName("  infra  "), "infra")
        XCTAssertEqual(BoardSwitcher.sanitizedName("infra"), "infra")
        XCTAssertEqual(BoardSwitcher.sanitizedName("   "), "", "whitespace-only clears the name")
        XCTAssertEqual(BoardSwitcher.sanitizedName(""), "")
    }

    func testIsTypableAcceptsPrintablesRejectsControlAndFunctionKeys() {
        XCTAssertTrue(BoardSwitcher.isTypable(scalar: UInt32(("a" as Unicode.Scalar).value)))
        XCTAssertTrue(BoardSwitcher.isTypable(scalar: 0x20), "space is typable")
        XCTAssertTrue(BoardSwitcher.isTypable(scalar: UInt32(("é" as Unicode.Scalar).value)))
        XCTAssertFalse(BoardSwitcher.isTypable(scalar: 0x1f), "control char")
        XCTAssertFalse(BoardSwitcher.isTypable(scalar: 0x7f), "DEL")
        // AppKit function/arrow/nav keys (private-use 0xF700–0xF8FF) are rejected.
        XCTAssertFalse(BoardSwitcher.isTypable(scalar: 0xF700), "NSUpArrowFunctionKey")
        XCTAssertFalse(BoardSwitcher.isTypable(scalar: 0xF729), "NSHomeFunctionKey")
        XCTAssertFalse(BoardSwitcher.isTypable(scalar: 0xF8FF), "private-use top")
    }
}
