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

    // MARK: - Text padding

    /// A text field pads its text by a fixed 2 a side whatever its font, so the
    /// field's own width does not scale with the zoom. The room it takes in the
    /// row is its text plus that padding scaled like every other metric.
    func testATextItemTakesItsTextsWidthAndThePaddingScaled() {
        XCTAssertEqual(CardHeaderLayout.textItemWidth(text: 44.1, scale: 1), 48.1)
        XCTAssertEqual(CardHeaderLayout.textItemWidth(text: 22.05, scale: 0.5), 24.05)
        XCTAssertEqual(CardHeaderLayout.textItemWidth(text: 88.2, scale: 2), 96.2)
        XCTAssertEqual(CardHeaderLayout.textItemWidth(text: 0, scale: 0.1), 0.4)
    }

    func testATextItemsRoomScalesExactlyWithTheZoom() {
        let full = CardHeaderLayout.textItemWidth(text: 75.6, scale: 1)
        for zoom: CGFloat in [0.1, 0.37, 0.5, 2.2, 3] {
            XCTAssertEqual(CardHeaderLayout.textItemWidth(text: 75.6 * zoom, scale: zoom), full * zoom, accuracy: 1e-9)
        }
    }

    /// The field's own width: its text and the padding unscaled, rounded up so
    /// a fraction of a point never truncates the text.
    func testATextFieldIsItsTextAndThePaddingRoundedUp() {
        XCTAssertEqual(CardHeaderLayout.textFieldWidth(text: 44.1), 49)
        XCTAssertEqual(CardHeaderLayout.textFieldWidth(text: 44), 48)
        XCTAssertEqual(CardHeaderLayout.textFieldWidth(text: 0.63), 5)
    }

    /// The field itself keeps its measured width, so it hangs over its place
    /// in the row by the padding that did not scale.
    func testATextFieldOverhangsItsPlaceByThePaddingThatDidNotScale() {
        XCTAssertEqual(CardHeaderLayout.textOverhang(scale: 1), 0)
        XCTAssertEqual(CardHeaderLayout.textOverhang(scale: 0.5), 1)
        XCTAssertEqual(CardHeaderLayout.textOverhang(scale: 0.1), 1.8, accuracy: 1e-12)
        XCTAssertEqual(CardHeaderLayout.textOverhang(scale: 2), -2)
    }

    func testWhenNothingIsLeftTheLabelCollapsesToZeroNotBelow() {
        let f = CardHeaderLayout.frames(width: 100, leading: [12, 7], label: 80, trailing: [60, 20])
        XCTAssertEqual(f.label.width, 0)
        XCTAssertEqual(f.trailing, [Span(x: 4, width: 60), Span(x: 70, width: 20)])
    }
}
