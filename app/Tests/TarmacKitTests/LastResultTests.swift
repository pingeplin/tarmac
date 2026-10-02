import XCTest
@testable import TarmacKit

final class LastResultTests: XCTestCase {
    func testTheSameInputIsWorkedOutOnce() {
        var result = LastResult<Int, Int>()
        var runs = 0
        let double: (Int) -> Int = { runs += 1; return $0 * 2 }
        XCTAssertEqual(result.value(for: 4, double), 8)
        XCTAssertEqual(result.value(for: 4, double), 8)
        XCTAssertEqual(runs, 1)
    }

    func testAnotherInputIsWorkedOutAgain() {
        var result = LastResult<Int, Int>()
        var runs = 0
        let double: (Int) -> Int = { runs += 1; return $0 * 2 }
        _ = result.value(for: 4, double)
        XCTAssertEqual(result.value(for: 5, double), 10)
        XCTAssertEqual(runs, 2)
    }

    func testOnlyTheLastInputIsRemembered() {
        var result = LastResult<Int, Int>()
        var runs = 0
        let double: (Int) -> Int = { runs += 1; return $0 * 2 }
        _ = result.value(for: 4, double)
        _ = result.value(for: 5, double)
        XCTAssertEqual(result.value(for: 4, double), 8)
        XCTAssertEqual(runs, 3)
    }

    func testAForgottenResultIsWorkedOutAgain() {
        var result = LastResult<Int, Int>()
        var runs = 0
        let double: (Int) -> Int = { runs += 1; return $0 * 2 }
        _ = result.value(for: 4, double)
        result.forget()
        XCTAssertEqual(result.value(for: 4, double), 8)
        XCTAssertEqual(runs, 2)
    }
}
