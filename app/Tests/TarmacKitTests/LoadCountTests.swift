import XCTest
@testable import TarmacKit

final class LoadCountTests: XCTestCase {
    func testOnlyTheLastLoadIsCurrent() {
        var loads = LoadCount()
        let first = loads.next()
        XCTAssertTrue(loads.isCurrent(first))

        let second = loads.next()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(loads.isCurrent(first), "the load that was replaced")
        XCTAssertTrue(loads.isCurrent(second))
    }

    /// A word that comes before anything was loaded is for no load.
    func testNothingIsCurrentBeforeTheFirstLoad() {
        let loads = LoadCount()
        for number in [-1, 0, 1] {
            XCTAssertFalse(loads.isCurrent(number), "\(number)")
        }
    }
}
