import XCTest
@testable import TarmacKit

/// ECMAScript `Math.round`: ties go toward +∞, so a negative half rounds up.
final class HalfUpRoundingTests: XCTestCase {
    func testPositiveHalvesRoundUp() {
        XCTAssertEqual(2.5.roundedHalfUp, 3)
        XCTAssertEqual(0.5.roundedHalfUp, 1)
        XCTAssertEqual(2.7.roundedHalfUp, 3)
        XCTAssertEqual(2.4.roundedHalfUp, 2)
    }

    func testNegativeHalvesRoundTowardPositiveInfinity() {
        XCTAssertEqual((-2.5).roundedHalfUp, -2)
        XCTAssertEqual((-0.5).roundedHalfUp, 0)
        XCTAssertEqual((-2.6).roundedHalfUp, -3)
        XCTAssertEqual((-2.4).roundedHalfUp, -2)
    }

    /// 0.49999999999999994 is the largest double below one half: adding 0.5 first
    /// would round it up to 1.
    func testTheLargestDoubleBelowAHalfRoundsDown() {
        XCTAssertEqual(0.49999999999999994.roundedHalfUp, 0)
    }

    func testIntegersAndNonFiniteValuesPassThrough() {
        XCTAssertEqual(7.0.roundedHalfUp, 7)
        XCTAssertTrue(Double.nan.roundedHalfUp.isNaN)
        XCTAssertEqual(Double.infinity.roundedHalfUp, .infinity)
    }

    func testWorksOnCGFloat() {
        XCTAssertEqual(CGFloat(393.5).roundedHalfUp, 394)
    }
}
