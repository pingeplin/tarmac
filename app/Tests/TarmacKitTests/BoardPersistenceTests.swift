import CoreGraphics
import XCTest
@testable import TarmacKit

/// Phase 2c: the persistence-snapshot round-trip (card world frames + board
/// viewport) and the pure world↔view board transform. Replaces the grid-only
/// `DeskLayoutTests` (the desk grid was retired with `DeskGridView`).
final class BoardPersistenceTests: XCTestCase {
    // MARK: - Layout snapshot round-trip (card frames + board viewport)

    /// A `layout` whose tiles carry full world frames (`x/y/w/h/z`) and a board
    /// `{zoom,cx,cy}` survives encode → decode byte-for-byte at the struct level.
    /// This is the exact shape `AppController.persistLayout()` sends and the
    /// daemon round-trips through `persist.rs`.
    func testLayoutWithCardFramesAndViewportRoundTrips() throws {
        let message = Message.layout(
            dock: ["/repo/plan.md", "/repo/notes.md"],
            tiles: [
                LayoutTile(kind: "term", x: 80, y: 80, w: 470, h: 330, z: 0),
                LayoutTile(kind: "doc", path: "/repo/plan.md", x: 648, y: 80, w: 392, h: 310, z: 1),
                LayoutTile(kind: "doc", path: "/repo/notes.md", x: 1126.5, y: 80, w: 392, h: 310, z: 2),
            ],
            board: BoardViewport(zoom: 0.82, cx: 640.25, cy: 360),
            boardID: nil
        )
        let decoded = try Message.decode(payload: message.encodedPayload())
        XCTAssertEqual(decoded, message)

        guard case .layout(let dock, let tiles, let board, _) = decoded else {
            return XCTFail("not a layout")
        }
        XCTAssertEqual(dock.count, 2)
        XCTAssertEqual(tiles.count, 3)
        // Geometry survives exactly (IEEE-754 doubles, fractional values included).
        XCTAssertEqual(tiles[0].kind, "term")
        XCTAssertEqual(tiles[0].x, 80)
        XCTAssertEqual(tiles[0].z, 0)
        XCTAssertEqual(tiles[2].x, 1126.5)
        XCTAssertEqual(board?.zoom, 0.82)
        XCTAssertEqual(board?.cx, 640.25)
    }

    /// The same for `restore` (daemon → app): card frames + viewport reproduce.
    func testRestoreWithCardFramesAndViewportRoundTrips() throws {
        let message = Message.restore(
            docs: [RestoreDoc(path: "/repo/plan.md", via: "cli")],
            tiles: [
                LayoutTile(kind: "term", x: 80, y: 80, w: 470, h: 330, z: 0),
                LayoutTile(kind: "doc", path: "/repo/plan.md", x: 648, y: 140, w: 392, h: 310, z: 1),
            ],
            board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
            boardID: nil,
            liveTerms: []
        )
        XCTAssertEqual(try Message.decode(payload: message.encodedPayload()), message)
    }

    /// The M1 → v4 migration premise: a geometry-less layout (M1 tiles, no
    /// `board`) decodes with all-nil tile geometry and a nil viewport, so the app
    /// can detect "no geometry" and apply the default scatter.
    func testGeometrylessTilesDecodeAsNilGeometry() throws {
        let m1 = Message.layout(
            dock: ["/a.md"],
            tiles: [LayoutTile(kind: "term"), LayoutTile(kind: "doc", path: "/a.md")],
            board: nil,
            boardID: nil
        )
        guard case .layout(_, let tiles, let board, _) = try Message.decode(payload: m1.encodedPayload()) else {
            return XCTFail("not a layout")
        }
        XCTAssertNil(board)
        for tile in tiles {
            XCTAssertNil(tile.x)
            XCTAssertNil(tile.y)
            XCTAssertNil(tile.w)
            XCTAssertNil(tile.h)
            XCTAssertNil(tile.z)
            // v4 Phase 5b: a legacy term/doc tile carries no term_id.
            XCTAssertNil(tile.termID)
        }
    }

    // MARK: - v4 Phase 5b: multiple terminal cards persist distinct positions

    /// A layout carrying two terminal tiles with distinct `term_id`s (plus a doc)
    /// survives encode → decode with both ids preserved, distinct, and in order —
    /// the persistence half of "multiple terminal cards" (the wire half of the
    /// daemon `set_tiles` dedup-by-term_id). The `term_id` key is emitted only on
    /// term tiles; the doc tile carries none.
    func testMultipleTerminalTilesRoundTripWithDistinctTermIDs() throws {
        let message = Message.layout(
            dock: ["/repo/plan.md"],
            tiles: [
                LayoutTile(kind: "term", x: 80, y: 80, w: 470, h: 330, z: 0, termID: "t1"),
                LayoutTile(kind: "term", x: 600, y: 80, w: 470, h: 330, z: 1, termID: "t2"),
                LayoutTile(kind: "doc", path: "/repo/plan.md", x: 1126, y: 80, w: 392, h: 310, z: 2),
            ],
            board: BoardViewport(zoom: 1.0, cx: 0, cy: 0),
            boardID: nil
        )
        let decoded = try Message.decode(payload: message.encodedPayload())
        XCTAssertEqual(decoded, message)

        guard case .layout(_, let tiles, _, _) = decoded else { return XCTFail("not a layout") }
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles[0].termID, "t1")
        XCTAssertEqual(tiles[1].termID, "t2")
        XCTAssertNotEqual(tiles[0].termID, tiles[1].termID)
        XCTAssertNil(tiles[2].termID, "a doc tile carries no term_id")
    }

    // MARK: - World↔view transform (crib §5)

    /// `view = (world − center)·zoom + viewportCenter`, inverted exactly.
    func testWorldViewRoundTrip() {
        let center = CGPoint(x: 640, y: 360)
        let viewportCenter = CGPoint(x: 550, y: 350)
        for zoom in [CGFloat(0.36), 0.5, 0.82, 1.0, 2.5] {
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 123.5, y: -42), CGPoint(x: 1280, y: 720)] {
                let v = BoardTransform.worldToView(p, zoom: zoom, center: center, viewportCenter: viewportCenter)
                let back = BoardTransform.viewToWorld(v, zoom: zoom, center: center, viewportCenter: viewportCenter)
                XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
            }
        }
    }

    /// The world center always projects to the view-space viewport center,
    /// independent of zoom (the pivot of the transform).
    func testCenterMapsToViewportCenter() {
        let center = CGPoint(x: 100, y: 200)
        let viewportCenter = CGPoint(x: 550, y: 350)
        for zoom in [CGFloat(0.36), 1.0, 3.0] {
            let v = BoardTransform.worldToView(center, zoom: zoom, center: center, viewportCenter: viewportCenter)
            XCTAssertEqual(v.x, viewportCenter.x, accuracy: 1e-9)
            XCTAssertEqual(v.y, viewportCenter.y, accuracy: 1e-9)
        }
    }

    /// At zoom 1 with center == viewportCenter, world and view coincide (identity).
    func testIdentityAtUnitZoomAlignedCenter() {
        let c = CGPoint(x: 300, y: 300)
        let p = CGPoint(x: 412, y: 88)
        let v = BoardTransform.worldToView(p, zoom: 1, center: c, viewportCenter: c)
        XCTAssertEqual(v, p)
    }

    /// One world unit maps to `zoom` view units (scale check).
    func testZoomScalesWorldDeltas() {
        let center = CGPoint(x: 0, y: 0)
        let viewportCenter = CGPoint(x: 400, y: 300)
        let zoom: CGFloat = 0.5
        let a = BoardTransform.worldToView(CGPoint(x: 0, y: 0), zoom: zoom, center: center, viewportCenter: viewportCenter)
        let b = BoardTransform.worldToView(CGPoint(x: 100, y: 100), zoom: zoom, center: center, viewportCenter: viewportCenter)
        XCTAssertEqual(b.x - a.x, 50, accuracy: 1e-9)
        XCTAssertEqual(b.y - a.y, 50, accuracy: 1e-9)
    }
}
