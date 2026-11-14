import CoreGraphics
import XCTest
import TarmacKit

/// #358: the restore card of a first-visit restore with cold spawns.
final class RestoreCardTests: XCTestCase {
    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        BoardRestore.Term(termID: id, frame: .zero, z: 0, spawn: spawn, resume: resume)
    }

    private func plan(_ terms: [BoardRestore.Term]) -> BoardRestore.Plan {
        BoardRestore.Plan(terms: terms, docs: [], droppedDocPaths: [])
    }

    func testColdSpawnsInTheirFoldersShowTheCardWithTheSummaryLines() {
        let card = RestoreCard.make(plan: plan([
            term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A"), resume: "echo HI"),
            term("b", spawn: SpawnRequest(cwd: "/b", succeeds: "B")),
        ]))
        XCTAssertEqual(card?.lines, ["✓ 2 terminals back in their folders", "↻ 1 with an agent session to resume"])
    }

    func testTheFooterIsAnyKeyToContinue() {
        XCTAssertEqual(RestoreCard.footer, "any key to continue")
    }

    func testAPlanOfReboundTerminalsShowsNoCard() {
        XCTAssertNil(RestoreCard.make(plan: plan([term("a", spawn: nil)])))
    }

    /// A fresh board's first terminal is a cold spawn with no folder: it was
    /// never restored, so there is nothing to tell.
    func testAFreshBoardsFirstTerminalShowsNoCard() {
        XCTAssertNil(RestoreCard.make(plan: plan([term("a", spawn: SpawnRequest())])))
    }

    func testAColdSpawnWithNoFolderAndNoResumeShowsNoCard() {
        XCTAssertNil(RestoreCard.make(plan: plan([term("a", spawn: SpawnRequest(succeeds: "A"))])))
    }
}
