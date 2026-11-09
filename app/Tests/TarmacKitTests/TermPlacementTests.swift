import CoreGraphics
import XCTest
@testable import TarmacKit

final class TermPlacementTests: XCTestCase {
    // MARK: - ⌘T

    func testANewTerminalLandsRightOfThePrimeAtItsTop() {
        let prime = CGRect(x: 300, y: 200, width: 470, height: 330)
        XCTAssertEqual(
            TermPlacement.newTerminalFrame(prime: prime, existing: [prime]),
            CGRect(x: 856, y: 200, width: 470, height: 330)
        )
    }

    func testWithNoPrimeItCirclesTheBootFrame() {
        XCTAssertEqual(
            TermPlacement.newTerminalFrame(prime: nil, existing: []),
            CGRect(x: 636, y: 80, width: 470, height: 330)
        )
    }

    /// The size is the boot size whatever the prime card was resized to.
    func testTheSizeIsAlwaysTheBootSize() {
        let prime = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(
            TermPlacement.newTerminalFrame(prime: prime, existing: [prime]),
            CGRect(x: 886, y: 0, width: 470, height: 330)
        )
    }

    /// A doc already right of the prime sends the terminal to the next slot
    /// clockwise: below the prime, left-aligned.
    func testItTakesTheNextRingSlotWhenTheFirstIsTaken() {
        let prime = Placement.termFrame
        let doc = Placement.firstFreeSlot(owner: prime, existing: [prime])
        XCTAssertEqual(
            TermPlacement.newTerminalFrame(prime: prime, existing: [prime, doc]),
            CGRect(x: 80, y: 450, width: 470, height: 330)
        )
    }

    func testTheFirstGeometryLessTerminalTakesTheBootFrame() {
        XCTAssertEqual(TermPlacement.restoredFrame(index: 0), CGRect(x: 80, y: 80, width: 470, height: 330))
    }

    func testLaterGeometryLessTerminalsStepDownRight() {
        XCTAssertEqual(TermPlacement.restoredFrame(index: 1), CGRect(x: 123, y: 120, width: 470, height: 330))
        XCTAssertEqual(TermPlacement.restoredFrame(index: 3), CGRect(x: 209, y: 200, width: 470, height: 330))
    }
}
