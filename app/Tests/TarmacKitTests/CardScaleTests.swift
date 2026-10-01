import CoreGraphics
import XCTest
@testable import TarmacKit

/// A card's chrome is laid out at its size on screen: world metrics times the
/// zoom, with edges on whole device pixels.
final class CardScaleTests: XCTestCase {
    private func scale(_ zoom: CGFloat, backing: CGFloat = 2) -> CardScale {
        CardScale(zoom: zoom, backing: backing)
    }

    func testAWorldLengthIsMultipliedByTheZoom() {
        XCTAssertEqual(scale(0.5).length(30), 15)
        XCTAssertEqual(scale(2.2).length(10), 22)
        XCTAssertEqual(scale(1).length(10.5), 10.5)
    }

    func testAScreenCoordinateMovesToTheNearestDevicePixel() {
        XCTAssertEqual(scale(1).aligned(11.1), 11)
        XCTAssertEqual(scale(1).aligned(11.3), 11.5)
        XCTAssertEqual(scale(1).aligned(11.8), 12)
        XCTAssertEqual(scale(1, backing: 1).aligned(11.4), 11)
        XCTAssertEqual(scale(1, backing: 1).aligned(11.6), 12)
    }

    func testASnappedLengthIsTheZoomedLengthOnWholeDevicePixels() {
        XCTAssertEqual(scale(0.37).snapped(30), 11)
        XCTAssertEqual(scale(0.37, backing: 1).snapped(30), 11)
        XCTAssertEqual(scale(0.55, backing: 1).snapped(30), 17)
        XCTAssertEqual(scale(1).snapped(30), 30)
    }

    // MARK: - Lines

    func testALineKeepsItsWidthAtFullSize() {
        XCTAssertEqual(scale(1).line(1), 1)
        XCTAssertEqual(scale(1, backing: 1).line(1), 1)
    }

    func testALineScalesWithTheZoomInWholeDevicePixelsRoundedDown() {
        XCTAssertEqual(scale(3).line(1), 3)
        XCTAssertEqual(scale(1.7).line(1), 1.5)
        XCTAssertEqual(scale(1.7, backing: 1).line(1), 1)
        XCTAssertEqual(scale(0.5).line(1), 0.5)
    }

    func testALineIsNeverThinnerThanOneDevicePixel() {
        XCTAssertEqual(scale(0.1).line(1), 0.5)
        XCTAssertEqual(scale(0.37, backing: 1).line(1), 1)
        XCTAssertEqual(scale(0.98).line(1), 0.5)
    }

    /// `1.2 × (1 / 1.2)` is a hair off 1 in floating point, and must not cost
    /// the border a device pixel.
    func testAZoomAHairBelowAWholePixelDoesNotRoundTheLineDown() {
        let nearlyOne: CGFloat = 1.2 * (1 / 1.2) - 1e-12
        XCTAssertLessThan(nearlyOne, 1)
        XCTAssertEqual(scale(nearlyOne).line(1), 1)
    }
}
