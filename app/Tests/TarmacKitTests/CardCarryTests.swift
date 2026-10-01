import CoreGraphics
import XCTest
@testable import TarmacKit

/// A terminal's attached docs travel with it while its header is dragged, and
/// with no other card.
final class CardCarryTests: XCTestCase {
    private let carry = CardCarry(
        owner: "term",
        ownerOrigin: CGPoint(x: 100, y: 100),
        satellites: ["a": CGPoint(x: 600, y: 100), "b": CGPoint(x: 600, y: 450)]
    )

    func testTheSatellitesFollowTheirOwnerByItsTravel() {
        XCTAssertEqual(
            carry.origins(moving: "term", to: CGPoint(x: 130, y: 60)),
            ["a": CGPoint(x: 630, y: 60), "b": CGPoint(x: 630, y: 410)]
        )
    }

    /// Each step is measured from where the owner was pressed, so the
    /// satellites retrace the owner's path instead of accumulating its steps.
    func testTheTravelIsMeasuredFromThePressNotFromTheLastStep() {
        _ = carry.origins(moving: "term", to: CGPoint(x: 300, y: 300))
        XCTAssertEqual(
            carry.origins(moving: "term", to: CGPoint(x: 100, y: 100)),
            ["a": CGPoint(x: 600, y: 100), "b": CGPoint(x: 600, y: 450)]
        )
    }

    func testAnotherCardsMoveCarriesNothing() {
        XCTAssertEqual(carry.origins(moving: "other", to: CGPoint(x: 130, y: 60)), [:])
        XCTAssertEqual(carry.origins(moving: "a", to: CGPoint(x: 0, y: 0)), [:])
    }

    func testAnOwnerWithNoSatellitesCarriesNothing() {
        let alone = CardCarry(owner: "term", ownerOrigin: .zero, satellites: [String: CGPoint]())
        XCTAssertEqual(alone.origins(moving: "term", to: CGPoint(x: 50, y: 50)), [:])
    }
}
