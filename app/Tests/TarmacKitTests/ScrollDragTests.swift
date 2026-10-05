import CoreGraphics
import XCTest
@testable import TarmacKit

/// A drag of the scroll thumb: the inverse of `ScrollIndicator.thumb` (spec
/// 2610.0004).
final class ScrollDragTests: XCTestCase {
    private let body = CGRect(x: 0, y: 30, width: 390, height: 280)

    private func metrics(_ offset: Double, _ visible: Double = 100, _ total: Double = 400) -> ScrollMetrics? {
        ScrollMetrics(offset: offset, visible: visible, total: total)
    }

    private func scale(_ zoom: CGFloat = 1, backing: CGFloat = 2) -> CardScale {
        CardScale(zoom: zoom, backing: backing)
    }

    /// The drag of S8: pressed 18 below the top of the thumb of `(0, 100, 400)`.
    private func pressed() throws -> ScrollDrag {
        let thumb = try XCTUnwrap(ScrollIndicator.frame(metrics(0), body: body, covered: 0, scale: scale()))
        XCTAssertEqual(thumb, CGRect(x: 378, y: 32, width: 10, height: 67))
        return ScrollDrag(pointerY: 50, thumb: thumb)
    }

    private func offset(
        _ drag: ScrollDrag, _ pointerY: CGFloat, metrics: ScrollMetrics?, body: CGRect? = nil, covered: CGFloat = 0
    ) -> Double? {
        drag.offset(pointerY: pointerY, metrics: metrics, body: body ?? self.body, covered: covered, scale: scale())
    }

    func test2610_0004S8ADragAsksForTheOffsetThatKeepsTheThumbUnderThePointer() throws {
        let drag = try pressed()
        XCTAssertEqual(drag.grab, 18)
        XCTAssertEqual(offset(drag, 150.5, metrics: metrics(0)), 150)
        XCTAssertEqual(offset(drag, 251, metrics: metrics(0)), 300)
        XCTAssertEqual(offset(drag, 50, metrics: metrics(0)), 0)
    }

    func test2610_0004S9TheOffsetIsTheInverseOfTheThumb() throws {
        let bodies: [(CGFloat, CGRect)] = [
            (0.5, CGRect(x: 0, y: 15, width: 195, height: 140)),
            (1, CGRect(x: 0, y: 30, width: 390, height: 280)),
            (2, CGRect(x: 0, y: 60, width: 780, height: 560)),
        ]
        for (zoom, body) in bodies {
            for backing: CGFloat in [1, 2] {
                for wanted in [0, 37, 150, 299.5, 300] {
                    let thumb = try XCTUnwrap(ScrollIndicator.thumb(metrics(wanted), track: 268))
                    let top = body.minY + (ScrollIndicator.inset + thumb.y) * zoom
                    let drag = ScrollDrag(pointerY: top + 7, thumb: CGRect(x: 0, y: top, width: 10, height: 1))
                    let answer = try XCTUnwrap(drag.offset(
                        pointerY: top + 7, metrics: metrics(0), body: body, covered: 0,
                        scale: scale(zoom, backing: backing)
                    ))
                    XCTAssertEqual(answer, wanted, accuracy: 1e-9, "zoom \(zoom), backing \(backing)")
                }
            }
        }
    }

    func test2610_0004S25TheOffsetIsClampedToTheContent() throws {
        let drag = try pressed()
        XCTAssertEqual(offset(drag, 0, metrics: metrics(0)), 0)
        XCTAssertEqual(offset(drag, 1000, metrics: metrics(0)), 300)
    }

    /// The same pointer, on the track as it is laid out then: more content,
    /// then an overlay that shortens the track.
    func test2610_0004S25TheDragFollowsTheTrackAsItIs() throws {
        let drag = try pressed()
        XCTAssertEqual(try XCTUnwrap(offset(drag, 150.5, metrics: metrics(0, 100, 800))), 300, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offset(drag, 111.5, metrics: metrics(0), covered: 112)), 150, accuracy: 1e-9)
    }

    func test2610_0004S25AThumbOfTheMinimumLengthIsDraggedOverItsOwnFreeTrack() throws {
        let long = metrics(9990, 10, 10000)
        let thumb = try XCTUnwrap(ScrollIndicator.frame(long, body: body, covered: 0, scale: scale()))
        XCTAssertEqual(thumb.height, 24)
        let drag = ScrollDrag(pointerY: thumb.minY, thumb: thumb)
        XCTAssertEqual(drag.grab, 0)
        XCTAssertEqual(try XCTUnwrap(offset(drag, 154, metrics: long)), 4995, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(offset(drag, 276, metrics: long)), 9990, accuracy: 1e-9)
    }

    func test2610_0004S31ThereIsNoOffsetWhereThereIsNothingToDrag() throws {
        let drag = try pressed()
        XCTAssertNil(offset(drag, 150.5, metrics: nil))
        XCTAssertNil(offset(drag, 150.5, metrics: metrics(0, 100, 100)))
        let short = CGRect(x: 0, y: 30, width: 160, height: 58)
        XCTAssertNil(offset(drag, 50, metrics: metrics(0), body: short, covered: 31))
        XCTAssertNil(offset(drag, 50, metrics: metrics(0), body: short, covered: 30))
        XCTAssertNotNil(ScrollIndicator.frame(metrics(0), body: short, covered: 30, scale: scale()))
    }
}
