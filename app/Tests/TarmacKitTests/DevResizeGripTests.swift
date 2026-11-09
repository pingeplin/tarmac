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
        let delta = { (from: CGSize, to: CGSize, zoom: CGFloat) in
            DevResizeGrip.delta(from: from, to: to, zoom: zoom, handle: .bottomRight)
        }
        XCTAssertEqual(delta(size(600, 400), size(800, 500), 0.5), CGVector(dx: 100, dy: 50))
        XCTAssertEqual(delta(size(600, 400), size(800, 600), 0.5), CGVector(dx: 100, dy: 100))
        XCTAssertEqual(delta(size(600, 400), size(800, 600), 1), CGVector(dx: 200, dy: 200))
        XCTAssertEqual(delta(size(800, 600), size(600, 400), 2), CGVector(dx: -400, dy: -400))
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

    /// The press must land where the card's own hit test finds the bottom-right
    /// handle, with or without a close button, at any size on screen.
    func testThePressPointIsInsideTheBottomRightHandle() {
        for hasClose in [true, false] {
            XCTAssertEqual(
                DevResizeGrip.pressPoint(.bottomRight, of: CGRect(x: 100, y: 50, width: 400, height: 300), hasClose: hasClose),
                CGPoint(x: 490, y: 340)
            )
        }
        for frame in [
            CGRect(x: 100, y: 50, width: 400, height: 300),
            CGRect(x: -700, y: 900, width: 80, height: 45),
            CGRect(x: 0, y: 0, width: 1410, height: 990),
        ] {
            for hasClose in [true, false] {
                let point = DevResizeGrip.pressPoint(.bottomRight, of: frame, hasClose: hasClose)!
                let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                XCTAssertEqual(
                    CardHandles.handle(at: local, cardSize: frame.size, hasClose: hasClose), .bottomRight, "\(frame)"
                )
            }
        }
    }

    /// `smoke.mjs` D3 and D10(b) read `to.w` / `to.h`: the size the card landed
    /// at, clamp included, never an echo of the request.
    func testTheReplyReportsBothSizesTheDeltaDraggedAndTheHandle() {
        XCTAssertEqual(
            DevResizeGrip.reply(
                from: size(600, 400), to: size(160, 90), delta: CGVector(dx: -590, dy: -390), handle: .bottomRight
            ),
            [
                "from": ["w": 600, "h": 400], "to": ["w": 160, "h": 90], "delta_px": ["dx": -590, "dy": -390],
                "handle": "bottom-right",
            ]
        )
    }

    // MARK: - any handle (#296)

    private let names: [(String, CardResize.Handle)] = [
        ("top-left", .topLeft), ("top", .top), ("top-right", .topRight), ("right", .right),
        ("bottom-right", .bottomRight), ("bottom", .bottom), ("bottom-left", .bottomLeft), ("left", .left),
    ]

    func testEachHandleHasOneWireName() {
        for (name, handle) in names {
            XCTAssertEqual(DevResizeGrip.handle(named: name), handle, name)
            XCTAssertEqual(DevResizeGrip.name(of: handle), name)
        }
        for bad in ["", "middle", "TOP-LEFT", "topLeft", "top_left"] {
            XCTAssertNil(DevResizeGrip.handle(named: bad), bad)
        }
    }

    /// Every handle's press lands where the card's own hit test finds that
    /// handle, at the smallest size a card can have too.
    func testEachHandlesPressPointIsInsideThatHandle() {
        for frame in [CGRect(x: 100, y: 50, width: 400, height: 300), CGRect(x: -700, y: 900, width: 160, height: 90)] {
            for hasClose in [true, false] {
                for handle in CardHandles.handles(hasClose: hasClose) {
                    guard let point = DevResizeGrip.pressPoint(handle, of: frame, hasClose: hasClose) else {
                        XCTFail("no press point for \(handle) on \(frame)")
                        continue
                    }
                    let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                    XCTAssertEqual(
                        CardHandles.handle(at: local, cardSize: frame.size, hasClose: hasClose), handle,
                        "\(handle) on \(frame), close button \(hasClose)"
                    )
                }
            }
        }
    }

    /// A doc card's ✕ sits where a top-right handle would.
    func testACardWithACloseButtonHasNoTopRightPressPoint() {
        XCTAssertNil(DevResizeGrip.pressPoint(.topRight, of: CGRect(x: 0, y: 0, width: 400, height: 300), hasClose: true))
    }

    /// A left or top handle grows the card when dragged left or up, and an edge
    /// handle drags along its own axis only.
    func testTheDragGoesTheWayTheHandleGrows() {
        let want: [(CardResize.Handle, CGVector)] = [
            (.bottomRight, CGVector(dx: 100, dy: 50)), (.topLeft, CGVector(dx: -100, dy: -50)),
            (.topRight, CGVector(dx: 100, dy: -50)), (.bottomLeft, CGVector(dx: -100, dy: 50)),
            (.right, CGVector(dx: 100, dy: 0)), (.left, CGVector(dx: -100, dy: 0)),
            (.bottom, CGVector(dx: 0, dy: 50)), (.top, CGVector(dx: 0, dy: -50)),
        ]
        for (handle, delta) in want {
            XCTAssertEqual(
                DevResizeGrip.delta(from: size(600, 400), to: size(800, 500), zoom: 0.5, handle: handle), delta,
                "\(handle)"
            )
        }
    }

    /// Each handle's drag, applied as the card applies it, lands at the size asked
    /// for on the axes that handle moves.
    func testEachHandlesDragLandsAtTheRequestedSize() {
        let start = CGRect(x: 100, y: 100, width: 600, height: 400)
        let landsAt: [CardResize.Handle: CGSize] = [
            .topLeft: size(800, 500), .topRight: size(800, 500), .bottomLeft: size(800, 500),
            .bottomRight: size(800, 500), .left: size(800, 400), .right: size(800, 400),
            .top: size(600, 500), .bottom: size(600, 500),
        ]
        for (handle, want) in landsAt {
            let delta = DevResizeGrip.delta(from: start.size, to: size(800, 500), zoom: 1, handle: handle)
            XCTAssertEqual(CardResize.frame(from: start, dragging: handle, by: delta).size, want, "\(handle)")
        }
    }
}
