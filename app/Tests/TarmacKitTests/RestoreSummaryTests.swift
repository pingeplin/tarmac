import CoreGraphics
import XCTest
import TarmacKit

/// 2611.0011 S11: the toast lines of a first-visit restore with cold spawns.
final class RestoreSummaryTests: XCTestCase {
    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        BoardRestore.Term(termID: id, frame: .zero, z: 0, spawn: spawn, resume: resume)
    }

    private func plan(_ terms: [BoardRestore.Term]) -> BoardRestore.Plan {
        BoardRestore.Plan(terms: terms, docs: [], droppedDocPaths: [])
    }

    func testS11FoldersAndResumesAreCountedAcrossColdSpawnsOnly() {
        let restored = plan([
            term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A")),
            term("b", spawn: SpawnRequest(cwd: "/b", succeeds: "B"), resume: "echo HI"),
            term("c", spawn: SpawnRequest(succeeds: "C")),
            term("d", spawn: nil),
        ])
        XCTAssertEqual(
            RestoreSummary.lines(plan: restored),
            ["✓ 2 terminals back in their folders", "↻ 1 with an agent session to resume"]
        )
    }

    func testS11OneFolderReadsInTheSingular() {
        XCTAssertEqual(
            RestoreSummary.lines(plan: plan([term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A"))])),
            ["✓ 1 terminal back in its folder"]
        )
    }

    func testS11NoColdSpawnGivesNoLine() {
        XCTAssertEqual(RestoreSummary.lines(plan: plan([term("d", spawn: nil)])), [])
    }

    func testAResumeWithNoFolderGivesOnlyItsLine() {
        XCTAssertEqual(
            RestoreSummary.lines(plan: plan([term("a", spawn: SpawnRequest(succeeds: "A"), resume: "echo HI")])),
            ["↻ 1 with an agent session to resume"]
        )
    }
}
