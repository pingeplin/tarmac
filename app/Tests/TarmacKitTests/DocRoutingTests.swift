import XCTest
@testable import TarmacKit

/// M3: per-board doc→terminal owner resolution (a doc binds to its terminal,
/// scoped to one board's owners + live terminals).
final class DocRoutingTests: XCTestCase {
    func testOwnerPresentAndLiveResolves() {
        let owner = DocRouting.resolveOwner(
            path: "/a.md",
            owners: ["/a.md": "t1"],
            liveTermIDs: ["t1", "t2"]
        )
        XCTAssertEqual(owner, "t1")
    }

    func testOwnerPresentButNotLiveIsNil() {
        // The owning terminal vanished (e.g. a stale id after a restart remap):
        // the doc stays loose.
        let owner = DocRouting.resolveOwner(
            path: "/a.md",
            owners: ["/a.md": "gone"],
            liveTermIDs: ["t1"]
        )
        XCTAssertNil(owner)
    }

    func testNoOwnerEntryIsNil() {
        let owner = DocRouting.resolveOwner(
            path: "/a.md",
            owners: [:],
            liveTermIDs: ["t1"]
        )
        XCTAssertNil(owner)
    }

    func testCrossBoardIsolation() {
        // The same doc/owner pair resolves only on the board whose live terminals
        // include the owner — board B (no t1) leaves it loose.
        let owners = ["/a.md": "t1"]
        let onBoardA = DocRouting.resolveOwner(path: "/a.md", owners: owners, liveTermIDs: ["t1"])
        let onBoardB = DocRouting.resolveOwner(path: "/a.md", owners: owners, liveTermIDs: ["t9"])
        XCTAssertEqual(onBoardA, "t1")
        XCTAssertNil(onBoardB)
    }

    // MARK: - docsOwnedBy (the inverse: a terminal's docs, for ⌘P focus targeting)

    func testDocsOwnedByReturnsEveryPathForThatTerminal() {
        let owned = DocRouting.docsOwnedBy(
            termID: "t1",
            owners: ["/a.md": "t1", "/b.md": "t2", "/c.md": "t1"]
        )
        // Order is unspecified (dictionary); membership is the contract.
        XCTAssertEqual(Set(owned), ["/a.md", "/c.md"])
    }

    func testDocsOwnedByIsEmptyWhenTerminalOwnsNothing() {
        XCTAssertTrue(DocRouting.docsOwnedBy(termID: "t9", owners: ["/a.md": "t1"]).isEmpty)
        XCTAssertTrue(DocRouting.docsOwnedBy(termID: "t1", owners: [:]).isEmpty)
    }
}
