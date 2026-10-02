import CoreGraphics
import XCTest
@testable import TarmacKit

/// The density a card is rasterised at: the display's own at or below 100 %,
/// then following the zoom up to a cap. The cases are those of the web app's
/// `rasterScale.test.ts`, without its half-step snapping — see `CardRaster`.
final class CardRasterTests: XCTestCase {
    func testAtFullSizeACardIsDrawnAtTheDisplaysDensity() {
        XCTAssertEqual(CardRaster.layerScale(backing: 2, zoom: 1), 2)
        XCTAssertEqual(CardRaster.layerScale(backing: 1, zoom: 1), 1)
    }

    func testBelowFullSizeTheDensityDoesNotDrop() {
        for zoom: CGFloat in [0.1, 0.5, 0.99] {
            XCTAssertEqual(CardRaster.layerScale(backing: 2, zoom: zoom), 2)
        }
    }

    func testAboveFullSizeTheDensityFollowsTheZoom() {
        XCTAssertEqual(CardRaster.layerScale(backing: 2, zoom: 1.01), 2.02, accuracy: 1e-12)
        XCTAssertEqual(CardRaster.layerScale(backing: 2, zoom: 1.5), 3)
        XCTAssertEqual(CardRaster.layerScale(backing: 1, zoom: 2.5), 2.5)
    }

    func testTheDensityIsCappedAtThreeTimesTheDisplays() {
        for zoom: CGFloat in [3, 3.1, 100] {
            XCTAssertEqual(CardRaster.layerScale(backing: 2, zoom: zoom), 6)
        }
    }
}
