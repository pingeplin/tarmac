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
}
