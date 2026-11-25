import XCTest

@testable import TarmacKit

final class ProvenanceTests: XCTestCase {
    // MARK: - edge geometry

    /// A straight segment between the two cards' centres. It is drawn beneath
    /// the cards, so only the gap between them shows.
    func testTheEdgeRunsFromTheOwnersCentreToTheCardsCentre() {
        let edge = Provenance.edge(
            owner: CGRect(x: 80, y: 80, width: 470, height: 330),
            card: CGRect(x: 636, y: 80, width: 392, height: 310)
        )
        XCTAssertEqual(edge, Provenance.Segment(from: CGPoint(x: 315, y: 245), to: CGPoint(x: 832, y: 235)))
    }

    // MARK: - which cards draw one (2611.0016)

    private let ownerFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let childFrame = CGRect(x: 200, y: 0, width: 100, height: 100)
    private let docFrame = CGRect(x: 0, y: 200, width: 100, height: 100)

    /// The owner `t1`, a term card it made (not attached, as planned) and a
    /// doc it opened.
    private func cards(owner: Bool = true) -> [String: Provenance.Card<String>] {
        var cards: [String: Provenance.Card<String>] = [
            "child": .init(frame: childFrame, owner: "t1", attached: false),
            "doc": .init(frame: docFrame, owner: "t1"),
        ]
        if owner { cards["t1"] = .init(frame: ownerFrame, owner: nil) }
        return cards
    }

    private func edges(_ cards: [String: Provenance.Card<String>]) -> [Provenance.Segment] {
        Provenance.edges(cards)
    }

    /// "Edge joins owner card to new card".
    func testATermCardWithAnOwnerOnTheBoardDrawsAnEdgeFromItsOwnersCentre() {
        let edges = edges(cards())

        XCTAssertTrue(edges.contains(Provenance.edge(owner: ownerFrame, card: childFrame)))
        XCTAssertTrue(edges.contains(Provenance.edge(owner: ownerFrame, card: docFrame)), "doc edges are unchanged")
        XCTAssertEqual(edges.count, 2)
    }

    /// "Edge joins owner card to new card".
    func testWithItsOwnerGoneNoCardDrawsAnEdge() {
        XCTAssertEqual(edges(cards(owner: false)), [])
    }

    func testADetachedDocKeepsItsEdge() {
        var all = cards()
        all["doc"]?.attached = false

        XCTAssertTrue(edges(all).contains(Provenance.edge(owner: ownerFrame, card: docFrame)))
    }

    // MARK: - which cards an owner's drag carries

    /// 2611.0016 "Owned term card is not attached to owner", D7: a terminal card starts not attached, so a term card
    /// with an owner is not carried; a doc starts attached.
    func testATermCardStartsNotAttachedAndADocDoes() {
        XCTAssertFalse(Provenance.startsAttached(isDoc: false))
        XCTAssertTrue(Provenance.startsAttached(isDoc: true))
    }

    func testAnOwnersDragCarriesTheAttachedCardsItMadeOnly() {
        XCTAssertEqual(Provenance.carried(by: "t1", among: cards()), ["doc": docFrame])
    }

    func testADetachedDocOrAnotherOwnersDocIsNotCarried() {
        var all = cards()
        all["doc"]?.attached = false
        all["other"] = .init(frame: docFrame, owner: "t2")

        XCTAssertEqual(Provenance.carried(by: "t1", among: all), [:])
    }
}
