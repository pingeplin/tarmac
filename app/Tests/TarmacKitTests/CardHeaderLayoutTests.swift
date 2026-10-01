import CoreGraphics
import XCTest
@testable import TarmacKit

/// The card header row: left items, label, spacer, right items — gap 6, side
/// padding 10, and only the label shrinks.
final class CardHeaderLayoutTests: XCTestCase {
    private typealias Span = CardHeaderLayout.Span

    func testLeftItemsStartAtThePaddingAndFollowEachOtherSixApart() {
        let f = CardHeaderLayout.frames(width: 392, leading: [12, 7], label: 80, trailing: [])
        XCTAssertEqual(f.leading, [Span(x: 10, width: 12), Span(x: 28, width: 7)])
        XCTAssertEqual(f.label, Span(x: 41, width: 80))
    }

    func testRightItemsPackAgainstTheRightPaddingInReadingOrder() {
        let f = CardHeaderLayout.frames(width: 392, leading: [12], label: 80, trailing: [60, 30, 20])
        XCTAssertEqual(f.trailing, [Span(x: 260, width: 60), Span(x: 326, width: 30), Span(x: 362, width: 20)])
    }

    func testALabelThatFitsKeepsItsNaturalWidth() {
        let f = CardHeaderLayout.frames(width: 392, leading: [12, 7], label: 80, trailing: [60, 20])
        XCTAssertEqual(f.label, Span(x: 41, width: 80))
    }

    /// The spacer between the label and the right items is an item too, so the
    /// label stops two gaps short of the first right item.
    func testALongLabelTakesExactlyTheRoomLeftAndStopsTwoGapsShortOfTheRightItems() {
        let f = CardHeaderLayout.frames(width: 392, leading: [12, 7], label: 900, trailing: [60, 20])
        XCTAssertEqual(f.label, Span(x: 41, width: 243))
        XCTAssertEqual(f.trailing[0].x - (f.label.x + f.label.width), 12)
    }

    func testWithNoRightItemsALongLabelStopsOneGapShortOfThePadding() {
        let f = CardHeaderLayout.frames(width: 200, leading: [14], label: 500, trailing: [])
        XCTAssertEqual(f.label, Span(x: 30, width: 154))
    }

    func testWithNoLeftItemsTheLabelStartsAtThePadding() {
        let f = CardHeaderLayout.frames(width: 200, leading: [], label: 50, trailing: [])
        XCTAssertEqual(f.label, Span(x: 10, width: 50))
    }

    /// The header is laid out at its size on screen: the padding and the gap
    /// scale with the zoom, the item widths arrive already scaled.
    func testThePaddingAndTheGapScaleWithTheZoom() {
        let f = CardHeaderLayout.frames(width: 196, leading: [6, 3.5], label: 40, trailing: [30, 10], scale: 0.5)
        XCTAssertEqual(f.leading, [Span(x: 5, width: 6), Span(x: 14, width: 3.5)])
        XCTAssertEqual(f.label, Span(x: 20.5, width: 40))
        XCTAssertEqual(f.trailing, [Span(x: 148, width: 30), Span(x: 181, width: 10)])

        let long = CardHeaderLayout.frames(width: 196, leading: [6, 3.5], label: 900, trailing: [30, 10], scale: 0.5)
        XCTAssertEqual(long.label, Span(x: 20.5, width: 121.5))
    }

    func testWhenNothingIsLeftTheLabelCollapsesToZeroNotBelow() {
        let f = CardHeaderLayout.frames(width: 100, leading: [12, 7], label: 80, trailing: [60, 20])
        XCTAssertEqual(f.label.width, 0)
        XCTAssertEqual(f.trailing, [Span(x: 4, width: 60), Span(x: 70, width: 20)])
    }
}
