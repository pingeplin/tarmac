import CoreGraphics
import XCTest
@testable import TarmacKit

/// `tarmac dev resize <card> <w>x<h>` (spec 2609.0015, #166): the drag on the
/// bottom-right handle, and the reply built from where the card landed.
final class DevResizeGripTests: XCTestCase {
    private func size(_ w: CGFloat, _ h: CGFloat) -> CGSize { CGSize(width: w, height: h) }

    /// The handle's drag is divided by zoom to get back to world units, so a
    /// delta left in world units resizes by `1/zoom` of what was asked. The
    /// asymmetric row comes first: every `dx == dy` row is also satisfied by an
    /// implementation that swaps the two axes.
    func testS43TheDeltaIsWorldUnitsScaledIntoScreenPoints() {
        XCTAssertEqual(DevResizeGrip.delta(from: size(600, 400), to: size(800, 500), zoom: 0.5), CGVector(dx: 100, dy: 50))
        XCTAssertEqual(DevResizeGrip.delta(from: size(600, 400), to: size(800, 600), zoom: 0.5), CGVector(dx: 100, dy: 100))
        XCTAssertEqual(DevResizeGrip.delta(from: size(600, 400), to: size(800, 600), zoom: 1), CGVector(dx: 200, dy: 200))
        XCTAssertEqual(DevResizeGrip.delta(from: size(800, 600), to: size(600, 400), zoom: 2), CGVector(dx: -400, dy: -400))
    }

    func testS44TheDragPressesAtTheHandleMovesByTheDeltaAndReleasesThere() {
        XCTAssertEqual(
            DevResizeGrip.drag(at: CGPoint(x: 300, y: 200), by: CGVector(dx: 100, dy: 50)),
            [
                DevResizeGrip.Step(phase: .press, location: CGPoint(x: 300, y: 200)),
                DevResizeGrip.Step(phase: .drag, location: CGPoint(x: 400, y: 250)),
                DevResizeGrip.Step(phase: .release, location: CGPoint(x: 400, y: 250)),
            ]
        )
    }

    func testS44AShrinkingDragMovesUpAndLeft() {
        let steps = DevResizeGrip.drag(at: CGPoint(x: 300, y: 200), by: CGVector(dx: -590, dy: -390))
        XCTAssertEqual(steps.map(\.location), [
            CGPoint(x: 300, y: 200), CGPoint(x: -290, y: -190), CGPoint(x: -290, y: -190),
        ])
    }

    /// `smoke.mjs` D3 and D10(b) read `to.w` / `to.h`: the size the card landed
    /// at, clamp included, never an echo of the request.
    func testTheReplyReportsBothSizesAndTheDeltaDragged() {
        XCTAssertEqual(
            DevResizeGrip.reply(from: size(600, 400), to: size(160, 90), delta: CGVector(dx: -590, dy: -390)),
            ["from": ["w": 600, "h": 400], "to": ["w": 160, "h": 90], "delta_px": ["dx": -590, "dy": -390]]
        )
    }
}
