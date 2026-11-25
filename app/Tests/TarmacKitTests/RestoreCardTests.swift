import CoreGraphics
import TarmacKit
import XCTest

/// #358 and 2611.0011 "Restore summary counts terminals and sessions": the restore card of a first-visit restore with cold
/// spawns, and its lines.
final class RestoreCardTests: XCTestCase {
    private typealias Line = RestoreCard.Line

    private func term(_ id: String, spawn: SpawnRequest?, resume: String? = nil) -> BoardRestore.Term {
        .fixture(id, spawn: spawn, resume: resume)
    }

    private func plan(_ terms: [BoardRestore.Term]) -> BoardRestore.Plan {
        BoardRestore.Plan(terms: terms, docs: [], droppedDocPaths: [])
    }

    private func folders(_ n: Int) -> Line { Line(glyph: "✓", text: "\(n) terminals back in their folders", ok: true) }
    private func resumes(_ n: Int) -> Line { Line(glyph: nil, text: "\(n) with an agent session to resume", ok: false) }

    /// "Restore summary counts terminals and sessions".
    func testFoldersAndResumesAreCountedAcrossColdSpawnsOnly() {
        let card = RestoreCard.make(
            plan: plan([
                term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A")),
                term("b", spawn: SpawnRequest(cwd: "/b", succeeds: "B"), resume: "echo HI"),
                term("c", spawn: SpawnRequest(succeeds: "C")),
                term("d", spawn: nil),
            ]))
        XCTAssertEqual(card?.lines, [folders(2), resumes(1)])
    }

    /// "Restore summary counts terminals and sessions".
    func testOneFolderReadsInTheSingular() {
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

    /// "Restore summary counts terminals and sessions".
    /// Only a cold spawn is counted: a rebound term carries no resume from a
    /// plan, and one that did would still not be offered.
    func testAPlanOfReboundTerminalsShowsNoCard() {
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

    // MARK: 2611.0015 "Restore card model lists choices and lines": the three choices, and no refresh glyph

    private let resumable = [
        BoardRestore.Term(
            termID: "a", frame: .zero, z: 0, spawn: SpawnRequest(cwd: "/a", succeeds: "A"), resume: "echo HI")
    ]

    /// "Restore card model lists choices and lines".
    func testAPlanWithAResumeGivesTheThreeChoicesInOrder() throws {
        let card = try XCTUnwrap(RestoreCard.make(plan: plan(resumable)))
        XCTAssertEqual(card.choices.map(\.text), ["⏎ resume all", "decide per card", "esc skip all"])
        XCTAssertEqual(card.choices.map(\.action), [.resumeAll, .perCard, .skipAll])
    }

    /// "Restore card model lists choices and lines".
    func testAPlanWithOnlyFolderLinesHasNoChoicesAndKeepsTheFooter() throws {
        let card = try XCTUnwrap(
            RestoreCard.make(plan: plan([term("a", spawn: SpawnRequest(cwd: "/a", succeeds: "A"))])))
        XCTAssertEqual(card.choices, [])
        XCTAssertEqual(RestoreCard.footer, "any key to continue")
    }

    /// "Restore card model lists choices and lines".
    func testTheResumeLineHasNoGlyphAndReadsAsItsTextAlone() {
        XCTAssertEqual(resumes(1).string, "1 with an agent session to resume")
    }

    /// "Restore card model lists choices and lines".
    func testNoLineOrChoiceHasTheRefreshGlyph() throws {
        let card = try XCTUnwrap(RestoreCard.make(plan: plan(resumable + [term("b", spawn: SpawnRequest(cwd: "/b"))])))
        let texts = card.lines.map(\.string) + card.choices.map(\.text) + [RestoreCard.footer]
        XCTAssertFalse(texts.contains { $0.contains("↻") }, "\(texts)")
    }
}
