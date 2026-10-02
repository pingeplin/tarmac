import CoreGraphics
import XCTest
@testable import TarmacKit

/// Where a QA-driver press lands and how it is delivered (spec 2609.0015, #166;
/// parity row Q21), and what a reply says about it.
final class DevPointerTests: XCTestCase {
    private typealias Candidate = DevPointer.Candidate
    private typealias Press = DevPointer.Press

    private let a = CGPoint(x: 300, y: 200)
    private let b = CGPoint(x: 50, y: 30)
    private let c = CGPoint(x: 150, y: 30)
    private let cell = CGSize(width: 10, height: 20)

    // MARK: - delivery

    /// A press that hit-tests to its target goes through the window like a
    /// user's; one that cannot is handed to the target, as a DOM event
    /// dispatched on an element is.
    func testAReachablePointIsPressedThroughTheWindowAndAnyOtherOnTheTarget() {
        XCTAssertEqual(DevPointer.Delivery(reachable: true), .window)
        XCTAssertEqual(DevPointer.Delivery(reachable: false), .target)
        XCTAssertEqual(DevPointer.Delivery.window.rawValue, "window")
        XCTAssertEqual(DevPointer.Delivery.target.rawValue, "target")
    }

    // MARK: - a card's body

    func testTheFirstReachablePointIsPressedThroughTheWindow() {
        XCTAssertEqual(
            DevPointer.press(among: [Candidate(point: a, reachable: true), Candidate(point: b, reachable: true)]),
            Press(point: a, delivery: .window)
        )
        XCTAssertEqual(
            DevPointer.press(among: [Candidate(point: a, reachable: false), Candidate(point: b, reachable: true)]),
            Press(point: b, delivery: .window)
        )
    }

    func testWithNoReachablePointTheFirstIsPressedOnTheTarget() {
        XCTAssertEqual(
            DevPointer.press(among: [Candidate(point: a, reachable: false), Candidate(point: b, reachable: false)]),
            Press(point: a, delivery: .target)
        )
    }

    /// A click on a link opens it in the user's browser; `focus` only focuses.
    func testAPointOnALinkIsNeverPressed() {
        XCTAssertEqual(
            DevPointer.press(among: [
                Candidate(point: a, reachable: true, onLink: true), Candidate(point: b, reachable: true),
            ]),
            Press(point: b, delivery: .window)
        )
        XCTAssertEqual(
            DevPointer.press(among: [
                Candidate(point: a, reachable: true, onLink: true), Candidate(point: b, reachable: false),
            ]),
            Press(point: b, delivery: .target)
        )
        XCTAssertNil(DevPointer.press(among: [Candidate(point: a, reachable: true, onLink: true)]))
        XCTAssertNil(DevPointer.press(among: []))
    }

    /// Two presses on one cell inside the double-click interval select a word,
    /// so the next press keeps two cells clear of the last one.
    func testAPointBesideTheLastPressIsPassedOver() {
        let candidates = [
            Candidate(point: a, reachable: true), Candidate(point: b, reachable: true),
            Candidate(point: c, reachable: true),
        ]
        XCTAssertEqual(DevPointer.press(among: candidates, last: a, cell: cell), Press(point: b, delivery: .window))
        XCTAssertEqual(DevPointer.press(among: candidates, last: b, cell: cell), Press(point: a, delivery: .window))
        XCTAssertEqual(
            DevPointer.press(among: candidates, last: CGPoint(x: 319, y: 239), cell: cell),
            Press(point: b, delivery: .window)
        )
    }

    func testTwoCellsAwayOnEitherAxisIsClear() {
        let candidates = [Candidate(point: a, reachable: true), Candidate(point: b, reachable: true)]
        XCTAssertEqual(
            DevPointer.press(among: candidates, last: CGPoint(x: 320, y: 200), cell: cell),
            Press(point: a, delivery: .window)
        )
        XCTAssertEqual(
            DevPointer.press(among: candidates, last: CGPoint(x: 300, y: 240), cell: cell),
            Press(point: a, delivery: .window)
        )
    }

    /// The spacing only ranks points; it never leaves a card unpressable.
    func testAPointBesideTheLastPressIsStillPressedWhenItIsTheOnlyOne() {
        XCTAssertEqual(
            DevPointer.press(among: [Candidate(point: a, reachable: false)], last: a, cell: cell),
            Press(point: a, delivery: .target)
        )
    }

    /// A reachable point beside the last press loses to an unreachable one
    /// clear of it: a word selection is a wrong result, the delivery is not.
    func testClearOfTheLastPressOutranksReachable() {
        XCTAssertEqual(
            DevPointer.press(
                among: [Candidate(point: a, reachable: true), Candidate(point: b, reachable: false)],
                last: a, cell: cell
            ),
            Press(point: b, delivery: .target)
        )
    }

    // MARK: - the bare board

    private let cards = [CGRect(x: 100, y: 50, width: 400, height: 300), CGRect(x: 600, y: -40, width: 200, height: 900)]

    func testABoardPointNothingCoversIsPressedThroughTheWindow() {
        XCTAssertEqual(
            DevPointer.boardPress(
                among: [Candidate(point: a, reachable: false), Candidate(point: b, reachable: true)], cards: cards
            ),
            Press(point: b, delivery: .window)
        )
    }

    /// With every point on screen under a card or an overlay, the press goes to
    /// the board at a point no card covers — never at one of the covered ones.
    func testWithNoBarePointOnScreenThePressIsOnTheBoardClearOfEveryCard() {
        let press = DevPointer.boardPress(among: [Candidate(point: a, reachable: false)], cards: cards)
        XCTAssertEqual(press.delivery, .target)
        XCTAssertNotEqual(press.point, a)
        for card in cards {
            XCTAssertFalse(card.insetBy(dx: -1, dy: -1).contains(press.point), "\(press.point) is on \(card)")
        }
        XCTAssertEqual(DevPointer.boardPress(among: [], cards: []).delivery, .target)
    }

    // MARK: - what the reply says

    func testAReplySaysHowItsInputGotIn() {
        XCTAssertEqual(
            DevInjection(activated: true, delivery: .target).annotate(["focused_card": "t-1"]),
            ["focused_card": "t-1", "activated": true, "delivery": "target"]
        )
        XCTAssertEqual(
            DevInjection(activated: false, delivery: .window).annotate(["focused_card": .null]),
            ["focused_card": .null, "activated": false, "delivery": "window"]
        )
    }

    /// A key verb presses nothing with the pointer.
    func testAVerbWithNoPointerHasNoDelivery() {
        XCTAssertEqual(
            DevInjection(activated: false).annotate(["combo": "ctrl+c"]), ["combo": "ctrl+c", "activated": false]
        )
    }

    func testTheVerbsOwnFieldsAreNeverReplaced() {
        XCTAssertEqual(
            DevInjection(activated: true, delivery: .window).annotate(["activated": "mine", "delivery": 7]),
            ["activated": "mine", "delivery": 7]
        )
    }
}
