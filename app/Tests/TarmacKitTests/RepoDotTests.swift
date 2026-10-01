import XCTest
@testable import TarmacKit

/// The header repo dot: present only for a doc with a repo colour.
final class RepoDotTests: XCTestCase {
    func testADocWithoutARepoColourHasNoDot() {
        XCTAssertNil(RepoDot.paletteIndex(repoColor: nil, paletteSize: 4))
    }

    func testAnIndexInsideThePaletteIsUsedAsIs() {
        XCTAssertEqual(RepoDot.paletteIndex(repoColor: 0, paletteSize: 4), 0)
        XCTAssertEqual(RepoDot.paletteIndex(repoColor: 3, paletteSize: 4), 3)
    }

    func testAnIndexPastThePaletteWrapsAround() {
        XCTAssertEqual(RepoDot.paletteIndex(repoColor: 4, paletteSize: 4), 0)
        XCTAssertEqual(RepoDot.paletteIndex(repoColor: 9, paletteSize: 4), 1)
    }

    func testANegativeIndexNamesNoColour() {
        XCTAssertNil(RepoDot.paletteIndex(repoColor: -1, paletteSize: 4))
    }

    func testAnEmptyPaletteNamesNoColour() {
        XCTAssertNil(RepoDot.paletteIndex(repoColor: 2, paletteSize: 0))
    }
}
