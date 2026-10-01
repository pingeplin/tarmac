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
}
