import XCTest
@testable import TarmacKit

/// Quiet dims the non-prime terminals beside a prime one — never a doc card.
final class CardDimTests: XCTestCase {
    func testANonPrimeTerminalIsQuietWhileItsBoardHasAPrime() {
        XCTAssertTrue(CardDim.isQuiet(terminal: true, prime: false, dead: false, boardHasPrime: true))
    }

    func testThePrimeTerminalIsNotQuiet() {
        XCTAssertFalse(CardDim.isQuiet(terminal: true, prime: true, dead: false, boardHasPrime: true))
    }

    func testNothingIsQuietWhenNoTerminalIsPrime() {
        XCTAssertFalse(CardDim.isQuiet(terminal: true, prime: false, dead: false, boardHasPrime: false))
    }

    func testADeadTerminalKeepsItsOwnDimAndIsNotQuiet() {
        XCTAssertFalse(CardDim.isQuiet(terminal: true, prime: false, dead: true, boardHasPrime: true))
    }

    func testADocCardIsNeverQuiet() {
        XCTAssertFalse(CardDim.isQuiet(terminal: false, prime: false, dead: false, boardHasPrime: true))
    }

    func testOpacityIsFullAtRestEightTenthsQuietAndJustOverHalfDead() {
        XCTAssertEqual(CardDim.opacity(dead: false, quiet: false), 1)
        XCTAssertEqual(CardDim.opacity(dead: false, quiet: true), 0.8)
        XCTAssertEqual(CardDim.opacity(dead: true, quiet: false), 0.55)
    }

    func testDeadOutranksQuiet() {
        XCTAssertEqual(CardDim.opacity(dead: true, quiet: true), 0.55)
    }
}
