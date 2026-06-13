import CoreGraphics
import Foundation
import TarmacKit

/// Identity of a card on the board — the v4 successor to `TileKey`
/// (DeskGridView.swift), kept as a separate type so Phase 2c can migrate the
/// app off the desk grid without colliding with the still-live `TileKey`.
/// `term` is the (single, this phase) terminal card; `doc(path)` is a doc card
/// keyed by registry path.
enum CardID: Hashable {
    case term
    case doc(String)
}

/// A card's world-space placement (crib §4/§5). `x,y,w,h` are world units; the
/// card layer is scaled+translated by the board viewport on every pan/zoom.
/// `z` is the stacking order (higher = front; select-to-front bumps it).
///
/// Maps 1:1 to the additive protocol keys `LayoutTile.x/y/w/h/z` (Phase 2a) —
/// 2c reads/writes these to persist layout.
struct CardFrame: Equatable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    var z: Int

    init(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, z: Int = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.z = z
    }

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    init(rect: CGRect, z: Int = 0) {
        self.init(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height, z: z)
    }
}

/// The persisted board viewport (crib §5/§9): zoom factor + world-space center.
/// Mirrors the protocol `board {zoom, cx, cy}` map (TarmacKit `BoardViewport`),
/// kept as a view-layer struct in CGFloat so BoardView never imports the wire
/// type. 2c bridges the two at the AppController boundary.
struct Viewport: Equatable {
    var zoom: CGFloat
    var cx: CGFloat
    var cy: CGFloat

    /// crib §5/§7: locards + denser 11px grid below ~50%. The board grows the
    /// `.lo` class below this; this phase only flips the grid density.
    static let semanticZoomThreshold: CGFloat = 0.5

    /// No min/max bounds are authored in the design sources (crib §5 observes
    /// 36%–100%); clamp loosely so pinch/⌘± stay usable without a hard cap.
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 3.0

    /// Default opening viewport when `restore.board` is nil (crib §9).
    static let `default` = Viewport(zoom: 1.0, cx: 0, cy: 0)

    var isSemanticZoom: Bool { zoom < Viewport.semanticZoomThreshold }
}

// MARK: - Wire bridging (AppController boundary)

extension Viewport {
    /// View-layer mirror of the wire `BoardViewport` (CGFloat ← Double).
    init(_ wire: BoardViewport) {
        self.init(zoom: CGFloat(wire.zoom), cx: CGFloat(wire.cx), cy: CGFloat(wire.cy))
    }

    /// The wire form persisted in `layout.board` / `restore.board`.
    var wire: BoardViewport {
        BoardViewport(zoom: Double(zoom), cx: Double(cx), cy: Double(cy))
    }
}

extension CardFrame {
    /// Builds a world frame from a restored tile's geometry, or nil when the
    /// tile carries no geometry (an M1 tile — caller applies the default scatter).
    init?(tile: LayoutTile) {
        guard let x = tile.x, let y = tile.y, let w = tile.w, let h = tile.h else { return nil }
        self.init(x: CGFloat(x), y: CGFloat(y), w: CGFloat(w), h: CGFloat(h), z: tile.z ?? 0)
    }
}
