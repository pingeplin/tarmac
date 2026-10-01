import CoreGraphics
import XCTest
@testable import TarmacKit

/// The first-visit half of `applyRestore` in `desktop/src/App.tsx`.
final class BoardRestoreTests: XCTestCase {
    private typealias Term = BoardRestore.Term
    private typealias Doc = BoardRestore.Doc

    private let boot = CGRect(x: 80, y: 80, width: 470, height: 330)

    /// Mints `new-1`, `new-2`, … so a cold spawn's id is recognisable.
    private func plan(
        _ tiles: [LayoutTile], docs: [RestoreDoc] = [], live: Set<String> = []
    ) -> BoardRestore.Plan {
        var minted = 0
        return BoardRestore.plan(tiles: tiles, docs: docs, liveTerms: live) {
            minted += 1
            return "new-\(minted)"
        }
    }

    private func termTile(_ id: String?, x: Double = 10, y: Double = 20, z: Int? = 3) -> LayoutTile {
        LayoutTile(kind: "term", x: x, y: y, w: 500, h: 300, z: z, termID: id)
    }

    private func docTile(_ path: String, x: Double = 700, loose: Bool? = nil, z: Int? = 2) -> LayoutTile {
        LayoutTile(kind: "doc", path: path, x: x, y: 90, w: 392, h: 310, z: z, loose: loose)
    }

    private func registered(_ path: String, owner: String? = nil) -> RestoreDoc {
        RestoreDoc(path: path, via: "cli", termID: owner)
    }

    // MARK: - terminals

    func testATileWhoseTerminalIsStillLiveReBindsUnderItsId() {
        let restored = plan([termTile("t0")], live: ["t0"])
        XCTAssertEqual(
            restored.terms,
            [Term(termID: "t0", frame: CGRect(x: 10, y: 20, width: 500, height: 300), z: 3, needsSpawn: false)]
        )
    }

    /// An id is never reused for a new shell.
    func testATileWhoseTerminalIsGoneColdSpawnsUnderAFreshIdAtTheSameFrameAndZ() {
        let restored = plan([termTile("t0")], live: ["other"])
        XCTAssertEqual(
            restored.terms,
            [Term(termID: "new-1", frame: CGRect(x: 10, y: 20, width: 500, height: 300), z: 3, needsSpawn: true)]
        )
    }

    func testATileWithNoPersistedIdColdSpawns() {
        XCTAssertEqual(plan([termTile(nil)], live: ["t0"]).terms.map(\.needsSpawn), [true])
    }

    func testEachTileDecidesOnItsOwnAndTileOrderIsKept() {
        let restored = plan([termTile("t0"), termTile("t1"), termTile("t2")], live: ["t0", "t2"])
        XCTAssertEqual(restored.terms.map(\.termID), ["t0", "new-1", "t2"])
        XCTAssertEqual(restored.terms.map(\.needsSpawn), [false, true, false])
    }

    func testABoardWithNoTerminalTileGetsOneAtTheBootFrame() {
        let restored = plan([docTile("/a.md")], docs: [registered("/a.md")])
        XCTAssertEqual(restored.terms, [Term(termID: "new-1", frame: boot, z: 0, needsSpawn: true)])
    }

    func testAnEmptyRestoreStillYieldsOneTerminal() {
        XCTAssertEqual(plan([]).terms, [Term(termID: "new-1", frame: boot, z: 0, needsSpawn: true)])
    }

    func testAGeometryLessTerminalTileCascadesByItsIndex() {
        let bare = LayoutTile(kind: "term", termID: "t")
        let restored = plan([termTile("a"), bare, bare])
        XCTAssertEqual(
            restored.terms.map(\.frame),
            [
                CGRect(x: 10, y: 20, width: 500, height: 300),
                CGRect(x: 123, y: 120, width: 470, height: 330),
                CGRect(x: 166, y: 160, width: 470, height: 330),
            ]
        )
        XCTAssertEqual(restored.terms.map(\.z), [3, 0, 0])
    }

    func testUnknownTileKindsAreSkipped() {
        let restored = plan([LayoutTile(kind: "widget", x: 1, y: 1, w: 1, h: 1), termTile("t0")], live: ["t0"])
        XCTAssertEqual(restored.terms.map(\.termID), ["t0"])
        XCTAssertEqual(restored.docs, [])
    }

    // MARK: - docs

    func testADocTileKeepsItsFrameAndZ() {
        let restored = plan([termTile("t0"), docTile("/a.md")], docs: [registered("/a.md")], live: ["t0"])
        XCTAssertEqual(restored.docs.map(\.frame), [CGRect(x: 700, y: 90, width: 392, height: 310)])
        XCTAssertEqual(restored.docs.map(\.z), [2])
    }

    func testADocTileMissingFromTheRegistryIsDropped() {
        let restored = plan([docTile("/gone.md"), docTile("/a.md")], docs: [registered("/a.md")])
        XCTAssertEqual(restored.docs.map(\.path), ["/a.md"])
        XCTAssertEqual(restored.droppedDocPaths, ["/gone.md"])
    }

    func testAShelfTileAndADocTileWithoutAPathAreDropped() {
        let shelved = LayoutTile(kind: "doc", path: "/s.md", shelf: true)
        let pathless = LayoutTile(kind: "doc", x: 1, y: 1, w: 1, h: 1)
        let restored = plan([shelved, pathless], docs: [registered("/s.md")])
        XCTAssertEqual(restored.docs, [])
        XCTAssertEqual(restored.droppedDocPaths, [], "neither was ever a placeable tile")
    }

    func testGeometryLessDocsScatterInTwoColumnsRightOfTheBootTerminal() {
        let bare = { (path: String) in LayoutTile(kind: "doc", path: path) }
        let restored = plan(
            [bare("/a.md"), bare("/b.md"), bare("/c.md")],
            docs: [registered("/a.md"), registered("/b.md"), registered("/c.md")]
        )
        XCTAssertEqual(
            restored.docs.map(\.frame),
            [
                CGRect(x: 636, y: 80, width: 392, height: 310),
                CGRect(x: 1114, y: 80, width: 392, height: 310),
                CGRect(x: 636, y: 430, width: 392, height: 310),
            ]
        )
        XCTAssertEqual(restored.docs.map(\.z), [0, 0, 0])
    }

    /// Only a doc that is kept and has no geometry takes a scatter slot.
    func testDroppedAndPlacedDocsDoNotConsumeAScatterSlot() {
        let bare = { (path: String) in LayoutTile(kind: "doc", path: path) }
        let restored = plan(
            [bare("/gone.md"), docTile("/placed.md"), bare("/a.md")],
            docs: [registered("/placed.md"), registered("/a.md")]
        )
        XCTAssertEqual(restored.docs.last?.frame, CGRect(x: 636, y: 80, width: 392, height: 310))
    }

    // MARK: - provenance

    func testAnOwnerThatReBoundKeepsItsDocAttached() {
        let restored = plan(
            [termTile("t0"), docTile("/a.md")], docs: [registered("/a.md", owner: "t0")], live: ["t0"]
        )
        XCTAssertEqual(restored.docs.map(\.ownerTermID), ["t0"])
        XCTAssertEqual(restored.docs.map(\.attached), [true])
    }

    func testAnOwnerThatColdSpawnedIsFollowedToItsNewId() {
        let restored = plan([termTile("t0"), docTile("/a.md")], docs: [registered("/a.md", owner: "t0")])
        XCTAssertEqual(restored.docs.map(\.ownerTermID), ["new-1"])
        XCTAssertEqual(restored.docs.map(\.attached), [true])
    }

    func testALooseDocStaysLooseButKeepsItsOwner() {
        let restored = plan(
            [termTile("t0"), docTile("/a.md", loose: true)], docs: [registered("/a.md", owner: "t0")], live: ["t0"]
        )
        XCTAssertEqual(restored.docs.map(\.ownerTermID), ["t0"])
        XCTAssertEqual(restored.docs.map(\.attached), [false])
    }

    /// No fallback to the board's only terminal: an owner with no tile leaves
    /// the doc ownerless and detached.
    func testAnOwnerThatWasNotRestoredLeavesTheDocOwnerlessAndDetached() {
        let restored = plan(
            [termTile("t0"), docTile("/a.md")], docs: [registered("/a.md", owner: "vanished")], live: ["t0"]
        )
        XCTAssertEqual(restored.docs.map(\.ownerTermID), [nil])
        XCTAssertEqual(restored.docs.map(\.attached), [false])
    }

    func testADocWithNoRecordedOwnerIsDetached() {
        let restored = plan([termTile("t0"), docTile("/a.md")], docs: [registered("/a.md")], live: ["t0"])
        XCTAssertEqual(restored.docs.map(\.ownerTermID), [nil])
        XCTAssertEqual(restored.docs.map(\.attached), [false])
    }

    /// The terminal the plan adds to a board that persisted none owns nothing.
    func testTheGuaranteedTerminalIsNoOnesOwner() {
        let restored = plan([docTile("/a.md")], docs: [registered("/a.md", owner: "t0")])
        XCTAssertEqual(restored.docs.map(\.ownerTermID), [nil])
    }
}
