import CoreGraphics
import XCTest
@testable import TarmacKit

/// Phase 4 wayfinding math (crib §6–7): fit-to-cards bbox, the world↔minimap
/// mapping, and the offscreen-hint edge geometry. The AppKit overlays
/// (`ZoomControl` / `Minimap` / `OffscreenHints`) are thin shells over this.
final class BoardWayfindingTests: XCTestCase {
    // MARK: - Bounding box

    func testBoundingBoxUnionsAllRects() {
        let box = BoardWayfinding.boundingBox(of: [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 200, y: 50, width: 100, height: 100),
        ])
        XCTAssertEqual(box, CGRect(x: 0, y: 0, width: 300, height: 150))
    }

    func testBoundingBoxOfEmptyIsNil() {
        XCTAssertNil(BoardWayfinding.boundingBox(of: []))
    }

    // MARK: - Fit to cards

    /// Fit centers on the bbox and picks the largest zoom that keeps the box
    /// inside the usable (margin-reduced) viewport. Box 400×200, viewport
    /// 800×600, 10% margin → usable 640×480; zx=1.6, zy=2.4 → zoom = 1.6,
    /// clamped under max 3.
    func testFitCentersAndScalesToTheLimitingAxis() {
        let fit = BoardWayfinding.fit(
            cards: [CGRect(x: 100, y: 100, width: 400, height: 200)],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        )
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.center.x, 300, accuracy: 1e-9) // 100 + 400/2
        XCTAssertEqual(fit!.center.y, 200, accuracy: 1e-9) // 100 + 200/2
        XCTAssertEqual(fit!.zoom, 1.6, accuracy: 1e-9)
    }

    /// A box larger than the viewport zooms OUT (zoom < 1) to fit, still clamped
    /// to minZoom. Box 4000×4000, viewport 800×600, 10% margin → usable 640×480;
    /// min ratio = 480/4000 = 0.12.
    func testFitZoomsOutForOversizeBox() {
        let fit = BoardWayfinding.fit(
            cards: [CGRect(x: 0, y: 0, width: 4000, height: 4000)],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        )
        XCTAssertEqual(fit!.zoom, 0.12, accuracy: 1e-9)
    }

    func testFitClampsToMaxZoom() {
        // A tiny box would want a huge zoom; clamp at maxZoom.
        let fit = BoardWayfinding.fit(
            cards: [CGRect(x: 0, y: 0, width: 10, height: 10)],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        )
        XCTAssertEqual(fit!.zoom, 3.0, accuracy: 1e-9)
    }

    func testFitClampsToMinZoom() {
        let fit = BoardWayfinding.fit(
            cards: [CGRect(x: 0, y: 0, width: 100000, height: 100000)],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        )
        XCTAssertEqual(fit!.zoom, 0.1, accuracy: 1e-9)
    }

    func testFitOfNoCardsIsNil() {
        XCTAssertNil(BoardWayfinding.fit(
            cards: [],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        ))
    }

    /// Two cards: fit spans both, centered on their union.
    func testFitSpansMultipleCards() {
        let fit = BoardWayfinding.fit(
            cards: [
                CGRect(x: 0, y: 0, width: 200, height: 200),
                CGRect(x: 600, y: 0, width: 200, height: 200),
            ],
            viewportSize: CGSize(width: 800, height: 600),
            margin: 0.1,
            minZoom: 0.1,
            maxZoom: 3.0
        )
        // union = 0..800 x, 0..200 y → center 400,100.
        XCTAssertEqual(fit!.center.x, 400, accuracy: 1e-9)
        XCTAssertEqual(fit!.center.y, 100, accuracy: 1e-9)
        // usable 640×480; zx=640/800=0.8, zy=480/200=2.4 → 0.8.
        XCTAssertEqual(fit!.zoom, 0.8, accuracy: 1e-9)
    }

    // MARK: - Minimap mapping

    /// A world box maps into the minimap with uniform scale + centering, and the
    /// round-trip (world → minimap → world) is exact.
    func testMinimapMappingRoundTrips() {
        let worldBox = CGRect(x: -100, y: -50, width: 1320, height: 880)
        let mapping = BoardWayfinding.minimapMapping(
            worldBox: worldBox,
            minimapSize: CGSize(width: 132, height: 88),
            pad: 6
        )
        for p in [CGPoint(x: -100, y: -50), CGPoint(x: 560, y: 390), CGPoint(x: 1220, y: 830)] {
            let mm = mapping.toMinimap(p)
            let back = mapping.toWorld(mm)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        }
    }

    /// The scale is uniform (the smaller axis ratio) so the world aspect is
    /// preserved. World box 1320×880 into 132×88 with pad 6 → avail 120×76;
    /// sx=120/1320≈0.0909, sy=76/880≈0.0863 → uniform = 0.0863…
    func testMinimapMappingUsesUniformSmallerScale() {
        let worldBox = CGRect(x: 0, y: 0, width: 1320, height: 880)
        let mapping = BoardWayfinding.minimapMapping(
            worldBox: worldBox,
            minimapSize: CGSize(width: 132, height: 88),
            pad: 6
        )
        let expected = 76.0 / 880.0
        XCTAssertEqual(mapping.scale, expected, accuracy: 1e-9)
    }

    /// The world box origin maps to the padded, centered offset (the box is
    /// centered on the limiting axis).
    func testMinimapMappingCentersContent() {
        let worldBox = CGRect(x: 0, y: 0, width: 880, height: 880) // square
        let mapping = BoardWayfinding.minimapMapping(
            worldBox: worldBox,
            minimapSize: CGSize(width: 132, height: 88),
            pad: 6
        )
        // avail 120×76; square scaled by min(120/880, 76/880)=76/880 → 76 wide,
        // 76 tall. Centered horizontally: x offset = 6 + (120-76)/2 = 28.
        let o = mapping.toMinimap(CGPoint(x: 0, y: 0))
        XCTAssertEqual(o.x, 28, accuracy: 1e-9)
        XCTAssertEqual(o.y, 6, accuracy: 1e-9)
    }

    func testMinimapDegenerateBoxHasZeroScale() {
        let mapping = BoardWayfinding.minimapMapping(
            worldBox: CGRect(x: 5, y: 5, width: 0, height: 0),
            minimapSize: CGSize(width: 132, height: 88),
            pad: 6
        )
        XCTAssertEqual(mapping.scale, 0)
    }

    // MARK: - Offscreen-hint geometry

    func testHintPlacementInsideViewIsNil() {
        let p = BoardWayfinding.hintPlacement(
            cardCenterView: CGPoint(x: 400, y: 300),
            viewRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            inset: 18
        )
        XCTAssertNil(p)
    }

    func testHintPlacementPicksTheRightEdge() {
        let p = BoardWayfinding.hintPlacement(
            cardCenterView: CGPoint(x: 1200, y: 300),
            viewRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            inset: 18
        )
        XCTAssertEqual(p?.edge, .right)
        XCTAssertEqual(p?.along, 300) // y stays (within inset bounds)
    }

    func testHintPlacementPicksTopEdgeAndClampsAlong() {
        // Card far above and slightly left: top overshoot dominates; the x is
        // clamped into [inset, width-inset].
        let p = BoardWayfinding.hintPlacement(
            cardCenterView: CGPoint(x: -50, y: -500),
            viewRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            inset: 18
        )
        XCTAssertEqual(p?.edge, .top)
        XCTAssertEqual(p?.along, 18) // clamped to minX + inset
    }

    func testHintPlacementLeftEdge() {
        let p = BoardWayfinding.hintPlacement(
            cardCenterView: CGPoint(x: -100, y: 250),
            viewRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            inset: 18
        )
        XCTAssertEqual(p?.edge, .left)
        XCTAssertEqual(p?.along, 250)
    }

    func testHintPlacementBottomEdge() {
        let p = BoardWayfinding.hintPlacement(
            cardCenterView: CGPoint(x: 400, y: 900),
            viewRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            inset: 18
        )
        XCTAssertEqual(p?.edge, .bottom)
        XCTAssertEqual(p?.along, 400)
    }

    func testEdgeArrows() {
        XCTAssertEqual(BoardWayfinding.Edge.left.arrow, "←")
        XCTAssertEqual(BoardWayfinding.Edge.right.arrow, "→")
        XCTAssertEqual(BoardWayfinding.Edge.top.arrow, "↑")
        XCTAssertEqual(BoardWayfinding.Edge.bottom.arrow, "↓")
    }

    func testIsOffscreenByCenter() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(BoardWayfinding.isOffscreen(cardCenterWorld: CGPoint(x: 400, y: 300), viewportWorldRect: vp))
        XCTAssertTrue(BoardWayfinding.isOffscreen(cardCenterWorld: CGPoint(x: 900, y: 300), viewportWorldRect: vp))
    }

    // MARK: - Cascade placement (Phase 5b ⌘T)

    /// With no collision, the cascade lands exactly one (dx, dy) down-right.
    func testCascadeOriginOffsetsFromBase() {
        let o = BoardWayfinding.cascadeOrigin(
            base: CGPoint(x: 80, y: 80), existing: [], dx: 43, dy: 40
        )
        XCTAssertEqual(o, CGPoint(x: 123, y: 120))
    }

    /// A card already sitting at the first cascade slot nudges the new card one
    /// more step, so repeated ⌘T stair-steps instead of stacking.
    func testCascadeOriginNudgesOffExistingCard() {
        let base = CGPoint(x: 80, y: 80)
        // The prime card itself + a card already at the first cascade slot.
        let existing = [base, CGPoint(x: 123, y: 120)]
        let o = BoardWayfinding.cascadeOrigin(base: base, existing: existing, dx: 43, dy: 40)
        XCTAssertEqual(o, CGPoint(x: 166, y: 160))
    }

    /// Three successive spawns (feeding each result back in) stair-step with no
    /// two top-lefts coinciding.
    func testCascadeOriginThreeSpawnsAreDistinct() {
        let base = CGPoint(x: 80, y: 80)
        var existing = [base]
        var origins: [CGPoint] = []
        for _ in 0..<3 {
            let o = BoardWayfinding.cascadeOrigin(base: base, existing: existing, dx: 43, dy: 40)
            origins.append(o)
            existing.append(o)
        }
        XCTAssertEqual(origins, [
            CGPoint(x: 123, y: 120),
            CGPoint(x: 166, y: 160),
            CGPoint(x: 209, y: 200),
        ])
    }
}
