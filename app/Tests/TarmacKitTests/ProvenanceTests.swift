import XCTest
@testable import TarmacKit

final class ProvenanceTests: XCTestCase {
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

    // MARK: - which cards draw one (2611.0016)

    private let ownerFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let childFrame = CGRect(x: 200, y: 0, width: 100, height: 100)
    private let docFrame = CGRect(x: 0, y: 200, width: 100, height: 100)

    private func cards(owner: Bool = true) -> [String: Provenance.Card<String>] {
        var cards: [String: Provenance.Card<String>] = [
            "child": .init(frame: childFrame, owner: "t1", kind: .term),
            "doc": .init(frame: docFrame, owner: "t1", kind: .doc),
        ]
        if owner { cards["t1"] = .init(frame: ownerFrame, owner: nil, kind: .term) }
        return cards
    }

    func testS8ATermCardWithAnOwnerOnTheBoardDrawsAnEdgeFromItsOwnersCentre() {
        let edges = Provenance.edges(cards())

        XCTAssertTrue(edges.contains(Provenance.edge(owner: ownerFrame, doc: childFrame)))
        XCTAssertTrue(edges.contains(Provenance.edge(owner: ownerFrame, doc: docFrame)), "doc edges are unchanged")
        XCTAssertEqual(edges.count, 2)
    }

    func testS8WithItsOwnerGoneNoCardDrawsAnEdge() {
        XCTAssertEqual(Provenance.edges(cards(owner: false)), [])
    }

    func testADetachedDocKeepsItsEdge() {
        var all = cards()
        all["doc"]?.attached = false

        XCTAssertTrue(Provenance.edges(all).contains(Provenance.edge(owner: ownerFrame, doc: docFrame)))
    }

    // MARK: - which cards an owner's drag carries

    func testS30ATermCardWithAnOwnerIsNotCarriedByItsOwnersDrag() {
        XCTAssertEqual(Provenance.carried(by: "t1", among: cards()), ["doc": docFrame])
    }

    func testADetachedDocOrAnotherOwnersDocIsNotCarried() {
        var all = cards()
        all["doc"]?.attached = false
        all["other"] = .init(frame: docFrame, owner: "t2", kind: .doc)

        XCTAssertEqual(Provenance.carried(by: "t1", among: all), [:])
    }
}
