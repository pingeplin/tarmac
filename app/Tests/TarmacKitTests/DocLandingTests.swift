import CoreGraphics
import XCTest
@testable import TarmacKit

/// What a `doc_opened` does to a board: every open lands a card, whoever
/// opened it, and a doc already on the board is never moved or duplicated.
final class DocLandingTests: XCTestCase {
    // MARK: - a doc not yet on the board

    func testAnAgentsOpenLandsAFreshCardAttachedToItsTerminal() {
        XCTAssertEqual(
            DocLanding.decide(onBoard: false, via: "cli", termID: "t1", wasFresh: false),
            .land(fresh: true, attached: true)
        )
    }

    func testAUserOpenedDocLandsToo() {
        XCTAssertEqual(
            DocLanding.decide(onBoard: false, via: "user", termID: nil, wasFresh: false),
            .land(fresh: false, attached: false)
        )
    }

    /// Attached follows the terminal id alone, fresh the way it was opened.
    func testFreshAndAttachedAreDecidedIndependently() {
        XCTAssertEqual(
            DocLanding.decide(onBoard: false, via: "cli", termID: nil, wasFresh: false),
            .land(fresh: true, attached: false)
        )
        XCTAssertEqual(
            DocLanding.decide(onBoard: false, via: "user", termID: "t1", wasFresh: false),
            .land(fresh: false, attached: true)
        )
    }

    // MARK: - a doc already on the board

    func testAReopenByAnAgentMarksTheCardFreshAgain() {
        XCTAssertEqual(
            DocLanding.decide(onBoard: true, via: "cli", termID: "t1", wasFresh: false),
            .refresh(fresh: true)
        )
    }

    func testAReopenSomeOtherWayLeavesTheFreshMarkAsItWas() {
        XCTAssertEqual(DocLanding.decide(onBoard: true, via: "user", termID: nil, wasFresh: true), .refresh(fresh: true))
        XCTAssertEqual(DocLanding.decide(onBoard: true, via: "user", termID: nil, wasFresh: false), .refresh(fresh: false))
    }

    // MARK: - owner

    func testAReopenWithoutATerminalKeepsTheOwnerTheCardHad() {
        XCTAssertEqual(DocLanding.owner(opened: nil, current: "t1"), "t1")
        XCTAssertEqual(DocLanding.owner(opened: "t2", current: "t1"), "t2")
        XCTAssertNil(DocLanding.owner(opened: nil, current: nil))
    }

    // MARK: - anchor (P5)

    private let owner = CGRect(x: 500, y: 300, width: 470, height: 330)
    private let prime = CGRect(x: 10, y: 20, width: 470, height: 330)

    func testANewDocIsPlacedBesideItsOwnerTerminal() {
        XCTAssertEqual(DocLanding.anchor(owner: owner, prime: prime), owner)
    }

    func testWithoutAnOwnerOnTheBoardItIsPlacedBesideThePrimeTerminal() {
        XCTAssertEqual(DocLanding.anchor(owner: nil, prime: prime), prime)
    }

    func testWithNoTerminalAtAllItIsPlacedBesideTheBootFrame() {
        XCTAssertEqual(DocLanding.anchor(owner: nil, prime: nil), Placement.termFrame)
    }
}
