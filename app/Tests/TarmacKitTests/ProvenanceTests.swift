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
