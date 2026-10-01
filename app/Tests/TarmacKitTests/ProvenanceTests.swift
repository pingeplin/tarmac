import XCTest
@testable import TarmacKit

/// `edgeShown` (#39: a dragged doc keeps its edge).
final class ProvenanceTests: XCTestCase {
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
}
