import XCTest
@testable import TarmacKit

/// Issue #50 / spec 2607.0004: ESC's "dismiss fresh doc" rung clears the
/// highlight in place and never removes the card.
final class ClearFreshDocTests: XCTestCase {
    private struct Card: ClearableFreshDoc, Equatable {
        enum Kind { case doc, term }
        var kind: Kind
        var id: String
        var fresh: Bool

        var isFreshDoc: Bool { kind == .doc && fresh }
        mutating func clearFresh() { fresh = false }
    }

    private func doc(_ id: String, fresh: Bool) -> Card { Card(kind: .doc, id: id, fresh: fresh) }
    private func term(_ id: String) -> Card { Card(kind: .term, id: id, fresh: false) }

    func testS1ClearsFreshOnAFreshDocKeepingItsOtherFields() {
        let card = doc("/a.md", fresh: true)
        XCTAssertEqual(ClearFreshDoc.apply(to: [card]), [doc("/a.md", fresh: false)])
    }

    func testS2OnlyTheFreshCardChangesItsSiblingsAreUntouched() {
        let cards = [doc("/a.md", fresh: true), doc("/b.md", fresh: false), term("t1")]
        let result = ClearFreshDoc.apply(to: cards)
        XCTAssertEqual(result, [doc("/a.md", fresh: false), doc("/b.md", fresh: false), term("t1")])
        XCTAssertEqual(result.map(\.id), cards.map(\.id), "never removes or reorders a card")
    }

    func testS3IsANoOpWhenNothingIsFresh() {
        let cards = [doc("/a.md", fresh: false), term("t1")]
        XCTAssertEqual(ClearFreshDoc.apply(to: cards), cards)
    }

    func testS4ClearsEveryFreshDocWhenMoreThanOneIsFresh() {
        let result = ClearFreshDoc.apply(to: [doc("/a.md", fresh: true), doc("/b.md", fresh: true)])
        XCTAssertEqual(result.map(\.fresh), [false, false])
    }

    func testS5EmptyInputGivesEmptyOutput() {
        XCTAssertEqual(ClearFreshDoc.apply(to: [Card]()), [])
    }
}
