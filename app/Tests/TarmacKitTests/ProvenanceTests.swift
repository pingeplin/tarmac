import XCTest
@testable import TarmacKit

/// Phase 5b: the best-effort doc→terminal provenance re-anchoring across a
/// restart (decision 2). Terminal ptys are gone on restart, so persisted owner
/// ids never match the freshly-minted ones directly — `remappedOwners` bridges
/// them, with a single-terminal heuristic that keeps the common case lossless.
final class ProvenanceTests: XCTestCase {
    /// An owner whose terminal restored is rewritten to the reborn id.
    func testRemapsOwnerToRebornTerminal() {
        let owners = ["/a.md": "old1", "/b.md": "old2"]
        let oldToNew = ["old1": "new1", "old2": "new2"]
        let out = Provenance.remappedOwners(owners, oldToNew: oldToNew, soleTerminal: nil)
        XCTAssertEqual(out, ["/a.md": "new1", "/b.md": "new2"])
    }

    /// Single-terminal restart (the common case): every owner-bearing doc
    /// re-anchors to the one terminal, even a doc owned by an even-earlier id.
    func testSingleTerminalReanchorsAllDocsLosslessly() {
        let owners = ["/a.md": "old1", "/b.md": "ancient", "/c.md": "old1"]
        let oldToNew = ["old1": "boot"]
        let out = Provenance.remappedOwners(owners, oldToNew: oldToNew, soleTerminal: "boot")
        XCTAssertEqual(out, ["/a.md": "boot", "/b.md": "boot", "/c.md": "boot"])
    }

    /// Multi-terminal: a doc whose owning terminal genuinely vanished keeps its
    /// stale id (the caller then restores it loose), while a doc whose owner
    /// restored is remapped.
    func testMultiTerminalLeavesOrphanOwnerStale() {
        let owners = ["/a.md": "old1", "/orphan.md": "gone"]
        let oldToNew = ["old1": "new1", "old2": "new2"]
        let out = Provenance.remappedOwners(owners, oldToNew: oldToNew, soleTerminal: nil)
        XCTAssertEqual(out["/a.md"], "new1")
        XCTAssertEqual(out["/orphan.md"], "gone", "an orphaned owner is left stale (resolves to no card)")
    }

    /// No owners ⇒ nothing to remap.
    func testEmptyOwnersStaysEmpty() {
        let out = Provenance.remappedOwners([:], oldToNew: ["old1": "new1"], soleTerminal: "new1")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - edgeShown (#39: a dragged doc keeps its edge)

    /// The edge shows for an owner-linked doc whose owner card is present, with no
    /// notion of `attached` in the inputs — a dragged card must not hide it.
    func testOwnerLinkedDocWithOwnerPresentShowsEdge() {
        XCTAssertTrue(Provenance.edgeShown(ownerTermID: "term-1", ownerCardPresent: true))
    }

    func testOwnerlessDocShowsNoEdge() {
        XCTAssertFalse(Provenance.edgeShown(ownerTermID: nil, ownerCardPresent: false))
    }

    func testOwnerlessDocShowsNoEdgeEvenIfAnOwnerCardWereSomehowPresent() {
        XCTAssertFalse(Provenance.edgeShown(ownerTermID: nil, ownerCardPresent: true))
    }

    /// No dangling edge once the owner terminal has been closed.
    func testOwnerLinkedDocWhoseOwnerCardIsAbsentShowsNoEdge() {
        XCTAssertFalse(Provenance.edgeShown(ownerTermID: "term-1", ownerCardPresent: false))
    }

    // MARK: - edge geometry

    /// A straight segment between the two cards' centres. It is drawn beneath
    /// the cards, so only the gap between them shows.
    func testTheEdgeRunsFromTheOwnersCentreToTheDocsCentre() {
        let edge = Provenance.edge(
            owner: CGRect(x: 80, y: 80, width: 470, height: 330),
            doc: CGRect(x: 636, y: 80, width: 392, height: 310)
        )
        XCTAssertEqual(edge, Provenance.Segment(from: CGPoint(x: 315, y: 245), to: CGPoint(x: 832, y: 235)))
    }
}
