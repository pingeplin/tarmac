import CoreGraphics
import XCTest
import TarmacKit

/// #358 and 2611.0011 S11: the restore card of a first-visit restore with cold
/// spawns, and its lines.
final class RestoreCardTests: XCTestCase {
    private typealias Line = RestoreCard.Line

    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        BoardRestore.Term(termID: id, frame: .zero, z: 0, spawn: spawn, resume: resume)
    }

    private func plan(_ terms: [BoardRestore.Term]) -> BoardRestore.Plan {
        BoardRestore.Plan(terms: terms, docs: [], droppedDocPaths: [])
    }

    private func folders(_ n: Int) -> Line { Line(glyph: "✓", text: "\(n) terminals back in their folders", ok: true) }
    private func resumes(_ n: Int) -> Line { Line(glyph: "↻", text: "\(n) with an agent session to resume", ok: false) }

    func testS11FoldersAndResumesAreCountedAcrossColdSpawnsOnly() {
        let card = RestoreCard.make(plan: plan([
            term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A")),
            term("b", spawn: SpawnRequest(cwd: "/b", succeeds: "B"), resume: "echo HI"),
            term("c", spawn: SpawnRequest(succeeds: "C")),
            term("d", spawn: nil),
        ]))
        XCTAssertEqual(card?.lines, [folders(2), resumes(1)])
    }

    func testS11OneFolderReadsInTheSingular() {
        XCTAssertEqual(
            RestoreCard.make(plan: plan([term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A"))]))?.lines,
            [Line(glyph: "✓", text: "1 terminal back in its folder", ok: true)]
        )
    }

    func testAResumeWithNoFolderGivesOnlyItsLine() {
        XCTAssertEqual(
            RestoreCard.make(plan: plan([term("a", spawn: SpawnRequest(succeeds: "A"), resume: "echo HI")]))?.lines,
            [resumes(1)]
        )
    }

    func testALineReadsAsItsGlyphAndItsText() {
        XCTAssertEqual(folders(2).string, "✓ 2 terminals back in their folders")
    }

    /// Only a cold spawn is counted: a rebound term carries no resume from a
    /// plan, and one that did would still not be offered.
    func testS11APlanOfReboundTerminalsShowsNoCard() {
        XCTAssertNil(RestoreCard.make(plan: plan([term("d", spawn: nil, resume: "echo HI")])))
        XCTAssertNil(RestoreCard.make(plan: plan([term("d", spawn: nil)])))
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
