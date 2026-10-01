import XCTest
@testable import TarmacKit

/// K13: the ESC ladder — toasts, fly-back, un-borrow, fresh docs, a selected
/// doc — first match wins.
final class EscLadderTests: XCTestCase {
    private typealias Facts = EscLadder.Facts

    func testNothingToDoLeavesEscForTheTerminal() {
        XCTAssertNil(EscLadder.rung(Facts()))
    }

    func testEachRungAloneIsTaken() {
        XCTAssertEqual(EscLadder.rung(Facts(toastsShowing: true)), .clearToasts)
        XCTAssertEqual(EscLadder.rung(Facts(hasPreFlightViewport: true)), .flyBack)
        XCTAssertEqual(EscLadder.rung(Facts(cardBorrowed: true)), .unborrow)
        XCTAssertEqual(EscLadder.rung(Facts(hasFreshDoc: true)), .clearFreshDocs)
        XCTAssertEqual(EscLadder.rung(Facts(selectedIsDoc: true)), .deselectDoc)
    }

    /// The whole order in one walk: with everything pending, each ESC takes
    /// the first rung left.
    func testRungsAreTakenInOrder() {
        var facts = Facts(
            toastsShowing: true, hasPreFlightViewport: true, cardBorrowed: true, hasFreshDoc: true,
            selectedIsDoc: true
        )
        XCTAssertEqual(EscLadder.rung(facts), .clearToasts)
        facts.toastsShowing = false
        XCTAssertEqual(EscLadder.rung(facts), .flyBack)
        facts.hasPreFlightViewport = false
        XCTAssertEqual(EscLadder.rung(facts), .unborrow)
        facts.cardBorrowed = false
        XCTAssertEqual(EscLadder.rung(facts), .clearFreshDocs)
        facts.hasFreshDoc = false
        XCTAssertEqual(EscLadder.rung(facts), .deselectDoc)
        facts.selectedIsDoc = false
        XCTAssertNil(EscLadder.rung(facts))
    }

    /// The pair the old shell had backwards.
    func testToastsAreDismissedBeforeTheFlyBack() {
        XCTAssertEqual(EscLadder.rung(Facts(toastsShowing: true, hasPreFlightViewport: true)), .clearToasts)
    }

    func testFlyBackComesBeforeTheUnborrow() {
        XCTAssertEqual(EscLadder.rung(Facts(hasPreFlightViewport: true, cardBorrowed: true)), .flyBack)
    }

    func testUnborrowComesBeforeTheFreshDocs() {
        XCTAssertEqual(EscLadder.rung(Facts(cardBorrowed: true, hasFreshDoc: true)), .unborrow)
    }

    func testFreshDocsAreClearedBeforeTheSelectedDocIsDeselected() {
        XCTAssertEqual(EscLadder.rung(Facts(hasFreshDoc: true, selectedIsDoc: true)), .clearFreshDocs)
    }
}
