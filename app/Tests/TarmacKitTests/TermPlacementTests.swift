import CoreGraphics
import XCTest
@testable import TarmacKit

final class TermPlacementTests: XCTestCase {
    // MARK: - ⌘T

    func testANewTerminalCascadesFromThePrimeOrigin() {
        let frame = TermPlacement.newTerminalFrame(
            primeOrigin: CGPoint(x: 300, y: 200), existingOrigins: [CGPoint(x: 300, y: 200)]
        )
        XCTAssertEqual(frame, CGRect(x: 343, y: 240, width: 470, height: 330))
    }

    func testWithNoPrimeItCascadesFromTheBootOrigin() {
        let frame = TermPlacement.newTerminalFrame(primeOrigin: nil, existingOrigins: [])
        XCTAssertEqual(frame, CGRect(x: 123, y: 120, width: 470, height: 330))
    }

    /// The size is the boot size whatever the prime card was resized to: only
    /// the prime's origin is an input.
    func testTheSizeIsAlwaysTheBootSize() {
        let frame = TermPlacement.newTerminalFrame(primeOrigin: CGPoint(x: 0, y: 0), existingOrigins: [])
        XCTAssertEqual(frame.size, CGSize(width: 470, height: 330))
    }

    func testItStepsPastACardAlreadySittingOnTheCascadeSlot() {
        let frame = TermPlacement.newTerminalFrame(
            primeOrigin: CGPoint(x: 80, y: 80),
            existingOrigins: [CGPoint(x: 80, y: 80), CGPoint(x: 123, y: 120), CGPoint(x: 170, y: 164)]
        )
        XCTAssertEqual(frame.origin, CGPoint(x: 209, y: 200), "(166,160) is within 8 px of (170,164)")
    }

    func testANewTerminalGoesOnTop() {
        XCTAssertEqual(TermPlacement.newTerminalZ(existing: [0, 4, 2]), 5)
    }

    /// The top is never below zero, so a board of negative z values still gets 1.
    func testTheTopIsFlooredAtZero() {
        XCTAssertEqual(TermPlacement.newTerminalZ(existing: [-7, -2]), 1)
        XCTAssertEqual(TermPlacement.newTerminalZ(existing: []), 1)
    }

    // MARK: - restore

    func testTheFirstGeometryLessTerminalTakesTheBootFrame() {
        XCTAssertEqual(TermPlacement.restoredFrame(index: 0), CGRect(x: 80, y: 80, width: 470, height: 330))
    }

    func testLaterGeometryLessTerminalsStepDownRight() {
        XCTAssertEqual(TermPlacement.restoredFrame(index: 1), CGRect(x: 123, y: 120, width: 470, height: 330))
        XCTAssertEqual(TermPlacement.restoredFrame(index: 3), CGRect(x: 209, y: 200, width: 470, height: 330))
    }
}
