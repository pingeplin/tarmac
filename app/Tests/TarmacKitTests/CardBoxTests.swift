import CoreGraphics
import XCTest
@testable import TarmacKit

/// The card box: header and body sit inside the 1-wide border.
final class CardBoxTests: XCTestCase {
    private let size = CGSize(width: 470, height: 330)

    func testTheContentAreaIsTheCardInsetByItsBorder() {
        XCTAssertEqual(CardBox.content(of: size), CGRect(x: 1, y: 1, width: 468, height: 328))
    }

    func testTheHeaderSpansTheContentWidthAtThirtyHigh() {
        XCTAssertEqual(CardBox.header(of: size), CGRect(x: 0, y: 0, width: 468, height: 30))
    }

    func testTheBodyIsTheCardMinusTheHeaderAndBothBorders() {
        XCTAssertEqual(CardBox.body(of: size), CGRect(x: 0, y: 30, width: 468, height: 298))
    }

    func testACardTooSmallForItsHeaderHasAnEmptyBodyNotANegativeOne() {
        let tiny = CGSize(width: 1, height: 20)
        XCTAssertEqual(CardBox.content(of: tiny), CGRect(x: 1, y: 1, width: 0, height: 18))
        XCTAssertEqual(CardBox.body(of: tiny), CGRect(x: 0, y: 30, width: 0, height: 0))
    }

    func testTheCornerRadiusIsTen() {
        XCTAssertEqual(CardBox.cornerRadius, 10)
    }

    // MARK: - On screen

    private func screen(_ zoom: CGFloat, backing: CGFloat = 2, card: CGSize? = nil) -> CardBox.Screen {
        CardBox.screen(
            cardSize: card ?? CGSize(width: size.width * zoom, height: size.height * zoom),
            worldSize: size,
            scale: CardScale(zoom: zoom, backing: backing)
        )
    }

    func testAtFullSizeTheScreenLayoutIsTheWorldLayout() {
        for backing: CGFloat in [1, 2] {
            let box = screen(1, backing: backing)
            XCTAssertEqual(box.border, CardBox.borderWidth)
            XCTAssertEqual(box.cornerRadius, CardBox.cornerRadius)
            XCTAssertEqual(box.content, CardBox.content(of: size))
            XCTAssertEqual(box.header, CardBox.header(of: size))
            XCTAssertEqual(box.body, CardBox.body(of: size))
            XCTAssertEqual(box.bodySize, CardBox.body(of: size).size)
        }
    }

    /// What a terminal's grid is measured from: the zoom must never reach it.
    func testTheBodyIsLaidOutAtItsWorldSizeAtEveryZoom() {
        for zoom: CGFloat in [0.1, 0.37, 0.5, 1, 1.7, 3] {
            for backing: CGFloat in [1, 2] {
                XCTAssertEqual(screen(zoom, backing: backing).bodySize, CGSize(width: 468, height: 298))
            }
        }
    }

    func testTheBodysContainerIsItsWorldSizeTimesTheZoomBelowTheHeader() {
        XCTAssertEqual(screen(0.5).body, CGRect(x: 0, y: 15, width: 234, height: 149))
        XCTAssertEqual(screen(2).body, CGRect(x: 0, y: 60, width: 936, height: 596))
        let odd = screen(0.37)
        XCTAssertEqual(odd.body.origin, CGPoint(x: 0, y: 11))
        XCTAssertEqual(odd.body.width, 468 * 0.37, accuracy: 1e-9)
        XCTAssertEqual(odd.body.height, 298 * 0.37, accuracy: 1e-9)
    }

    func testTheHeaderIsThirtyTimesTheZoomOnWholeDevicePixels() {
        XCTAssertEqual(screen(0.5).header, CGRect(x: 0, y: 0, width: 234, height: 15))
        XCTAssertEqual(screen(0.37).header.height, 11)
        XCTAssertEqual(screen(0.55, backing: 1).header.height, 17)
        XCTAssertEqual(screen(2.2).header.height, 66)
    }

    func testTheBorderScalesWithTheZoomAndTheContentSitsInsideIt() {
        let half = screen(0.5)
        XCTAssertEqual(half.border, 0.5)
        XCTAssertEqual(half.content, CGRect(x: 0.5, y: 0.5, width: 234, height: 164))

        let far = screen(0.1, backing: 1, card: CGSize(width: 47, height: 33))
        XCTAssertEqual(far.border, 1)
        XCTAssertEqual(far.content, CGRect(x: 1, y: 1, width: 45, height: 31))
    }

    func testTheCornerRadiusScalesWithTheZoom() {
        XCTAssertEqual(screen(0.5).cornerRadius, 5)
        XCTAssertEqual(screen(3).cornerRadius, 30)
    }

    func testAHeaderTallerThanTheCardIsCutToIt() {
        let box = CardBox.screen(
            cardSize: CGSize(width: 100, height: 20),
            worldSize: CGSize(width: 100, height: 20),
            scale: CardScale(zoom: 1, backing: 2)
        )
        XCTAssertEqual(box.header.height, 18)
        XCTAssertEqual(box.bodySize, CGSize(width: 98, height: 0))
    }
}
