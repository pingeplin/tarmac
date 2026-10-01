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

    /// The box an HTML card's document is laid out in: the card minus its
    /// header, borders included.
    func testTheDocumentBoxIsTheCardMinusItsHeader() {
        XCTAssertEqual(CardBox.documentBox(of: CGSize(width: 392, height: 310)), CGSize(width: 392, height: 280))
        XCTAssertEqual(CardBox.documentBox(of: CGSize(width: 10, height: 20)), CGSize(width: 10, height: 0))
    }

    /// A card's body knows only its own size; the card's is that plus the
    /// header and both borders.
    func testTheCardSizeIsRecoveredFromItsBody() {
        XCTAssertEqual(CardBox.cardSize(ofBody: CardBox.body(of: size).size), size)
        XCTAssertEqual(CardBox.cardSize(ofBody: CGSize(width: 390, height: 278)), CGSize(width: 392, height: 310))
    }
}
