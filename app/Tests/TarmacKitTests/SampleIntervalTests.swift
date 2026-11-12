import XCTest
import TarmacKit

/// How often the app writes a sample line (spec 2611.0004, *The timer*).
final class SampleIntervalTests: XCTestCase {
    func testWithNoOverrideItIs300Seconds() {
        XCTAssertEqual(SampleInterval.seconds(override: nil), 300)
    }

    func testANumberOfAtLeastOneSecondReplacesIt() {
        XCTAssertEqual(SampleInterval.seconds(override: "5"), 5)
        XCTAssertEqual(SampleInterval.seconds(override: "1"), 1)
        XCTAssertEqual(SampleInterval.seconds(override: "2.5"), 2.5)
    }

    func testAnythingElseIsIgnored() {
        for value in ["", "0", "0.5", "-5", "abc", "5s", "inf", "nan"] {
            XCTAssertEqual(SampleInterval.seconds(override: value), 300, value)
        }
    }
}
