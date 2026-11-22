import TarmacKit
import XCTest

final class SpikeHeldTests: XCTestCase {
    func testPlantedAddsOneAboveThreeOnly() {
        XCTAssertEqual([0, 3, 4, 9].map(SpikeHeld.planted), [0, 3, 5, 10])
    }
}
