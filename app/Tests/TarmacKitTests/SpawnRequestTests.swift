import XCTest

@testable import TarmacKit

/// What a `spawn_term` carries beside its id, grid and board.
final class SpawnRequestTests: XCTestCase {
    func testAPlainSpawnCarriesNothing() {
        let request = SpawnRequest()
        XCTAssertNil(request.cwd)
        XCTAssertNil(request.succeeds)
        XCTAssertNil(request.inheritCwdFrom)
    }

    func testEachArgumentLandsInItsOwnField() {
        let request = SpawnRequest(cwd: "/work", succeeds: "t-old", inheritCwdFrom: "t-left")
        XCTAssertEqual(request.cwd, "/work")
        XCTAssertEqual(request.succeeds, "t-old")
        XCTAssertEqual(request.inheritCwdFrom, "t-left")
    }
}
