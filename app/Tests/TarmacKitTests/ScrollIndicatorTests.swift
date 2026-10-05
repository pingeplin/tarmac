import CoreGraphics
import XCTest
@testable import TarmacKit

/// The one scroll thumb every card kind wears: where it sits on its track,
/// its frame on screen, and when it shows (spec 2610.0003).
final class ScrollIndicatorTests: XCTestCase {
    private func metrics(_ offset: Double, _ visible: Double = 100, _ total: Double = 400) -> ScrollMetrics? {
        ScrollMetrics(offset: offset, visible: visible, total: total)
    }

    private func frame(
        _ offset: Double, zoom: CGFloat = 1, backing: CGFloat = 2,
        body: CGRect = CGRect(x: 0, y: 30, width: 390, height: 280), covered: CGFloat = 0
    ) -> CGRect? {
        ScrollIndicator.frame(metrics(offset), body: body, covered: covered, scale: CardScale(zoom: zoom, backing: backing))
    }

    // MARK: - thumb

    func testS3TheThumbIsTheVisibleShareOfTheTrackAtTheOffsetsShare() {
        XCTAssertEqual(ScrollIndicator.thumb(metrics(0), track: 200), ScrollIndicator.Thumb(y: 0, length: 50))
        XCTAssertEqual(ScrollIndicator.thumb(metrics(150), track: 200), ScrollIndicator.Thumb(y: 75, length: 50))
        XCTAssertEqual(ScrollIndicator.thumb(metrics(300), track: 200), ScrollIndicator.Thumb(y: 150, length: 50))
    }

    func testS4TheThumbIsNeverShorterThanItsMinimum() {
        XCTAssertEqual(
            ScrollIndicator.thumb(metrics(9990, 10, 10000), track: 200), ScrollIndicator.Thumb(y: 176, length: 24)
        )
    }

    func testS21ThereIsNoThumbForNothingToScrollOrNoRoom() {
        XCTAssertNil(ScrollIndicator.thumb(nil, track: 200))
        XCTAssertNil(ScrollIndicator.thumb(metrics(0, 100, 100), track: 200))
        XCTAssertNil(ScrollIndicator.thumb(metrics(0), track: 23.5))
        XCTAssertEqual(ScrollIndicator.thumb(metrics(0), track: 24), ScrollIndicator.Thumb(y: 0, length: 24))
    }

    // MARK: - frame

    /// Ten wide, two in from the body's right edge, two below its top, and
    /// clear of the card's rounded corner at the bottom.
    func testS5TheFrameSitsAtTheBodysRightEdge() {
        XCTAssertEqual(frame(0), CGRect(x: 378, y: 32, width: 10, height: 67))
        XCTAssertEqual(frame(300), CGRect(x: 378, y: 233, width: 10, height: 67))
        XCTAssertEqual(frame(300)?.maxY, 300)
        XCTAssertEqual(frame(150)?.minY, 132.5)
        XCTAssertEqual(frame(150, backing: 1)?.minY, 133)
        XCTAssertEqual(frame(0, body: CGRect(x: 10, y: 30, width: 390, height: 280))?.minX, 388)
    }

    func testS6TheFrameFollowsTheZoom() {
        let double = CGRect(x: 0, y: 60, width: 780, height: 560)
        XCTAssertEqual(frame(0, zoom: 2, body: double), CGRect(x: 756, y: 64, width: 20, height: 134))
        XCTAssertEqual(frame(300, zoom: 2, body: double)?.minY, 466)

        let half = CGRect(x: 0, y: 15, width: 195, height: 140)
        XCTAssertEqual(frame(0, zoom: 0.5, body: half), CGRect(x: 189, y: 16, width: 5, height: 33.5))
        XCTAssertEqual(frame(300, zoom: 0.5, body: half)?.minY, 116.5)
        XCTAssertEqual(frame(0, zoom: 0.5, backing: 1, body: half)?.height, 34)
        XCTAssertEqual(frame(300, zoom: 0.5, backing: 1, body: half)?.minY, 117)
    }

    /// Unsnapped these are 285.25, 99.875, 7.5 and 50.25; and x leaves room
    /// for the snapped width, or it would read 286.
    func testS6EveryTermOfTheFrameIsOnAWholeDevicePixel() {
        let body = CGRect(x: 0, y: 23, width: 294.75, height: 210)
        XCTAssertEqual(frame(150, zoom: 0.75, backing: 1, body: body), CGRect(x: 285, y: 100, width: 8, height: 50))
    }

    func testS7AnOverlayAtTheBodysBottomShortensTheTrack() {
        XCTAssertEqual(frame(300, covered: 112), CGRect(x: 378, y: 155, width: 10, height: 41))
        XCTAssertEqual(frame(300, covered: 112)?.maxY, 196)
        XCTAssertEqual(frame(300, covered: 4), frame(300))
        XCTAssertEqual(frame(300, covered: 4), CGRect(x: 378, y: 233, width: 10, height: 67))
    }

    func testS22ThereIsNoFrameWhereThereIsNoThumb() {
        let short = CGRect(x: 0, y: 30, width: 160, height: 58)
        let scale = CardScale(zoom: 1, backing: 2)
        XCTAssertNil(ScrollIndicator.frame(nil, body: short, covered: 0, scale: scale))
        XCTAssertNil(ScrollIndicator.frame(metrics(0, 100, 100), body: short, covered: 0, scale: scale))
        XCTAssertNil(frame(0, body: short, covered: 31))
        XCTAssertEqual(frame(0, body: short, covered: 30), CGRect(x: 148, y: 32, width: 10, height: 24))
    }

    // MARK: - visibility

    func testS8AThumbShowsFromAWheelUntilTheHoldEndsThenFades() {
        var visibility = ScrollIndicator.Visibility()
        for now in [0, 5000, UInt64.max] {
            XCTAssertEqual(visibility.alpha(atMs: now), 0, "never wheeled, at \(now)")
        }

        visibility.wheeled(atMs: 5000)
        let expected: [(UInt64, CGFloat)] = [
            (5000, 1), (6000, 1), (4000, 1), (6050, 0.75), (6100, 0.5), (6150, 0.25), (6200, 0), (9000, 0), (.max, 0),
        ]
        for (now, alpha) in expected {
            XCTAssertEqual(visibility.alpha(atMs: now), alpha, "at \(now)")
        }
    }

    func testS9AWheelDuringTheFadeRestoresTheThumb() {
        var visibility = ScrollIndicator.Visibility()
        visibility.wheeled(atMs: 5000)
        visibility.wheeled(atMs: 6100)
        XCTAssertEqual(visibility.alpha(atMs: 6100), 1)
        XCTAssertEqual(visibility.alpha(atMs: 7100), 1)
        XCTAssertEqual(visibility.alpha(atMs: 7200), 0.5)
        XCTAssertEqual(visibility.alpha(atMs: 7300), 0)
    }

    func testS9AResetHidesTheThumbAtOnceAndAWheelStartsAgain() {
        var visibility = ScrollIndicator.Visibility()
        visibility.wheeled(atMs: 5000)
        visibility.reset()
        for now in [0, 4000, 5000, 5500, 6100] as [UInt64] {
            XCTAssertEqual(visibility.alpha(atMs: now), 0, "reset, at \(now)")
        }

        visibility.wheeled(atMs: 8000)
        XCTAssertEqual(visibility.alpha(atMs: 8000), 1)
        XCTAssertEqual(visibility.alpha(atMs: 9000), 1)
    }

    func testS9AWheelAtTheEndOfTimeDoesNotTrap() {
        var visibility = ScrollIndicator.Visibility()
        visibility.wheeled(atMs: .max)
        XCTAssertEqual(visibility.alpha(atMs: .max), 1)
        XCTAssertEqual(visibility.alpha(atMs: 0), 1)
    }

    // MARK: - visibility: what holds the thumb (spec 2610.0004)

    private func wheeled(atMs now: UInt64) -> ScrollIndicator.Visibility {
        var visibility = ScrollIndicator.Visibility()
        visibility.wheeled(atMs: now)
        return visibility
    }

    private func assertAlpha(
        _ visibility: ScrollIndicator.Visibility, _ expected: [(UInt64, CGFloat)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for (now, alpha) in expected {
            XCTAssertEqual(visibility.alpha(atMs: now), alpha, "at \(now)", file: file, line: line)
        }
    }

    func test2610_0004S1ThePointerOverTheThumbHoldsIt() {
        var visibility = wheeled(atMs: 5000)
        visibility.pointer(over: true, atMs: 5500)
        assertAlpha(visibility, [(5500, 1), (6000, 1), (10000, 1)])

        visibility.pointer(over: false, atMs: 10000)
        assertAlpha(visibility, [(10000, 1), (11000, 1), (11100, 0.5), (11200, 0)])
    }

    func test2610_0004S2APressHoldsIt() {
        var visibility = wheeled(atMs: 1000)
        visibility.pressed(atMs: 1500)
        assertAlpha(visibility, [(9000, 1)])

        visibility.released(atMs: 9000)
        assertAlpha(visibility, [(10000, 1), (10100, 0.5), (10200, 0)])
    }

    func test2610_0004S3APointerThatArrivesInTheFadeRestoresIt() {
        var visibility = wheeled(atMs: 1000)
        assertAlpha(visibility, [(2100, 0.5)])

        visibility.pointer(over: true, atMs: 2100)
        assertAlpha(visibility, [(2100, 1), (60000, 1)])
    }

    func test2610_0004S4AThumbThatShowsAtAllCanBeGrabbed() {
        XCTAssertFalse(ScrollIndicator.Visibility().grabbable(atMs: 0))

        var visibility = wheeled(atMs: 1000)
        XCTAssertTrue(visibility.grabbable(atMs: 1000))
        XCTAssertTrue(visibility.grabbable(atMs: 2199))
        XCTAssertFalse(visibility.grabbable(atMs: 2200))

        visibility.pressed(atMs: 2500)
        XCTAssertTrue(visibility.grabbable(atMs: 2500))
        XCTAssertTrue(visibility.grabbable(atMs: 99999))
    }

    func test2610_0004S5TheFadeStartsWhenTheHoldEndsAndNotWhileHeld() {
        XCTAssertNil(ScrollIndicator.Visibility().fadeStartsAtMs(atMs: 0))

        let shown = wheeled(atMs: 5000)
        for now in [5000, 5999, 6100] as [UInt64] {
            XCTAssertEqual(shown.fadeStartsAtMs(atMs: now), 6000, "asked at \(now)")
        }
        XCTAssertNil(shown.fadeStartsAtMs(atMs: 6200))

        var hovered = wheeled(atMs: 5000)
        hovered.pointer(over: true, atMs: 5500)
        XCTAssertNil(hovered.fadeStartsAtMs(atMs: 5500))
        XCTAssertNil(hovered.fadeStartsAtMs(atMs: 7000))
        hovered.pointer(over: false, atMs: 8000)
        XCTAssertEqual(hovered.fadeStartsAtMs(atMs: 8000), 9000)

        var held = wheeled(atMs: 5000)
        held.pressed(atMs: 5500)
        XCTAssertNil(held.fadeStartsAtMs(atMs: 5500))
        XCTAssertNil(held.fadeStartsAtMs(atMs: 99999))
        held.released(atMs: 8000)
        XCTAssertEqual(held.fadeStartsAtMs(atMs: 8000), 9000)

        XCTAssertEqual(wheeled(atMs: .max).fadeStartsAtMs(atMs: .max), .max)
    }

    func test2610_0004S20HoverAloneShowsNothing() {
        var fresh = ScrollIndicator.Visibility()
        fresh.pointer(over: true, atMs: 100)
        assertAlpha(fresh, [(100, 0), (5000, 0)])
        fresh.wheeled(atMs: 6000)
        assertAlpha(fresh, [(7100, 0.5)])

        var faded = wheeled(atMs: 1000)
        faded.pointer(over: true, atMs: 2200)
        assertAlpha(faded, [(2200, 0), (3000, 0)])
    }

    func test2610_0004S21TheLastOfThePointerAndThePressLetsGo() {
        var pointerFirst = wheeled(atMs: 1000)
        pointerFirst.pointer(over: true, atMs: 1200)
        pointerFirst.pressed(atMs: 1300)
        pointerFirst.pointer(over: false, atMs: 4000)
        assertAlpha(pointerFirst, [(8000, 1)])
        pointerFirst.released(atMs: 9000)
        assertAlpha(pointerFirst, [(10000, 1), (10100, 0.5)])

        var pressFirst = wheeled(atMs: 1000)
        pressFirst.pointer(over: true, atMs: 1200)
        pressFirst.pressed(atMs: 1300)
        pressFirst.released(atMs: 4000)
        assertAlpha(pressFirst, [(8000, 1)])
        pressFirst.pointer(over: false, atMs: 9000)
        assertAlpha(pressFirst, [(10000, 1), (10100, 0.5)])
    }

    func test2610_0004S22ToldTheSameAgainNothingMoves() {
        var notOver = wheeled(atMs: 1000)
        notOver.pointer(over: false, atMs: 1900)
        assertAlpha(notOver, [(2100, 0.5)])

        var notPressed = wheeled(atMs: 1000)
        notPressed.released(atMs: 1900)
        assertAlpha(notPressed, [(2100, 0.5)])

        var over = wheeled(atMs: 1000)
        over.pointer(over: true, atMs: 1200)
        let once = over
        over.pointer(over: true, atMs: 5000)
        XCTAssertEqual(over, once)
        over.pointer(over: false, atMs: 6000)
        assertAlpha(over, [(7000, 1), (7100, 0.5)])
    }

    func test2610_0004S23AResetDropsThePointerAndThePress() {
        var visibility = wheeled(atMs: 1000)
        visibility.pointer(over: true, atMs: 1200)
        visibility.pressed(atMs: 1300)
        XCTAssertNotEqual(visibility, ScrollIndicator.Visibility())

        visibility.reset()
        XCTAssertEqual(visibility, ScrollIndicator.Visibility())
        assertAlpha(visibility, [(1300, 0)])
        XCTAssertFalse(visibility.grabbable(atMs: 1300))
        XCTAssertNil(visibility.fadeStartsAtMs(atMs: 1300))

        visibility.released(atMs: 1400)
        visibility.pointer(over: false, atMs: 1500)
        XCTAssertEqual(visibility, ScrollIndicator.Visibility())
        assertAlpha(visibility, [(1500, 0)])
    }

    func test2610_0004S35APressIsTakenWhateverTheAlpha() {
        var visibility = ScrollIndicator.Visibility()
        visibility.pressed(atMs: 100)
        assertAlpha(visibility, [(100, 1), (9000, 1)])

        visibility.released(atMs: 9000)
        assertAlpha(visibility, [(10000, 1), (10200, 0)])
    }
}
