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
}
