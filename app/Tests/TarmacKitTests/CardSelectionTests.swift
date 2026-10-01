import XCTest
@testable import TarmacKit

/// A board holds a selection only while it is on screen, and only of a card
/// it has.
final class CardSelectionTests: XCTestCase {
    private let cards: Set<String> = ["a", "b"]

    private func resolve(_ requested: String?, onScreen: Bool = true) -> String? {
        CardSelection.resolve(requested, onScreen: onScreen, isOnBoard: cards.contains)
    }

    func testABoardOnScreenSelectsACardItHas() {
        XCTAssertEqual(resolve("a"), "a")
    }

    func testACardTheBoardDoesNotHaveSelectsNothing() {
        XCTAssertNil(resolve("gone"))
    }

    func testABoardOffScreenSelectsNothingEvenOfItsOwnCards() {
        XCTAssertNil(resolve("a", onScreen: false))
    }

    func testClearingTheSelectionSelectsNothing() {
        XCTAssertNil(resolve(nil))
        XCTAssertNil(resolve(nil, onScreen: false))
    }
}
