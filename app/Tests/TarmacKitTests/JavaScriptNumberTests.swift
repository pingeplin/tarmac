import XCTest

@testable import TarmacKit

/// JavaScript's `String(number)` (ECMAScript Number::toString), at the edges of
/// each layout it chooses.
final class JavaScriptNumberTests: XCTestCase {
    private func assertWritten(_ cases: [(Double, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (value, text) in cases {
            XCTAssertEqual(value.javaScriptString, text, "\(value)", file: file, line: line)
        }
    }

    func testTheValuesThatAreNotDigits() {
        assertWritten([
            (.nan, "NaN"), (-Double.nan, "NaN"), (0, "0"), (-0.0, "0"), (.infinity, "Infinity"),
            (-.infinity, "-Infinity"),
        ])
    }

    func testAWholeNumberBelow10To21IsWrittenOutInFull() {
        assertWritten([
            (1, "1"), (10, "10"), (1e20, "100000000000000000000"),
            (9.999999999999999e20, "999999999999999900000"),
        ])
    }

    func testANumberWithAFractionIsWrittenOutInFull() {
        assertWritten([(1.5, "1.5"), (10.25, "10.25"), (123_456_789_012_345.6, "123456789012345.6")])
    }

    func testAFractionDownTo10ToMinus6IsWrittenOutInFull() {
        assertWritten([(0.5, "0.5"), (0.00001, "0.00001"), (0.000001, "0.000001"), (0.0000015, "0.0000015")])
    }

    func testBeyondThoseTheLayoutIsAnExponentWithItsSignAndNoPadding() {
        assertWritten([
            (1e21, "1e+21"), (2.5e21, "2.5e+21"), (1e-7, "1e-7"), (9.9e-7, "9.9e-7"), (1.25e-10, "1.25e-10"),
        ])
    }

    func testANegativeNumberIsItsMagnitudeAfterAMinus() {
        assertWritten([(-1, "-1"), (-0.5, "-0.5"), (-0.000001, "-0.000001"), (-1e21, "-1e+21"), (-1e-7, "-1e-7")])
    }
}
