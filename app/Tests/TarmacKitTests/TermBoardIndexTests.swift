import XCTest
@testable import TarmacKit

/// M3: the term_id → board_id ownership index that routes daemon term frames
/// (output/exit/signals) to the owning board and scopes board teardown.
final class TermBoardIndexTests: XCTestCase {
    func testAssignThenLookup() {
        var idx = TermBoardIndex()
        idx.assign(termID: "t1", to: "board-0")
        XCTAssertEqual(idx.board(of: "t1"), "board-0")
    }

    func testUnknownTermIsNil() {
        let idx = TermBoardIndex()
        XCTAssertNil(idx.board(of: "ghost"))
    }

    func testReassignMovesTerm() {
        // The "no two boards share a term_id" invariant: last assignment wins.
        var idx = TermBoardIndex()
        idx.assign(termID: "t1", to: "board-0")
        idx.assign(termID: "t1", to: "board-1")
        XCTAssertEqual(idx.board(of: "t1"), "board-1")
        XCTAssertEqual(idx.terms(of: "board-0"), [])
        XCTAssertEqual(idx.terms(of: "board-1"), ["t1"])
    }

    func testRemoveOrphansTheTerm() {
        var idx = TermBoardIndex()
        idx.assign(termID: "t1", to: "board-0")
        idx.remove(termID: "t1")
        XCTAssertNil(idx.board(of: "t1"))
    }

    func testRemoveBoardDropsAllItsTerms() {
        var idx = TermBoardIndex()
        idx.assign(termID: "t1", to: "board-0")
        idx.assign(termID: "t2", to: "board-0")
        idx.assign(termID: "t3", to: "board-1")
        idx.removeBoard("board-0")
        XCTAssertNil(idx.board(of: "t1"))
        XCTAssertNil(idx.board(of: "t2"))
        XCTAssertEqual(idx.board(of: "t3"), "board-1", "another board's terms survive")
    }

    func testTwoBoardsKeepDistinctTermSets() {
        var idx = TermBoardIndex()
        idx.assign(termID: "t1", to: "board-0")
        idx.assign(termID: "t2", to: "board-1")
        idx.assign(termID: "t3", to: "board-1")
        XCTAssertEqual(idx.terms(of: "board-0"), ["t1"])
        XCTAssertEqual(Set(idx.terms(of: "board-1")), ["t2", "t3"])
    }
}
