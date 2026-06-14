import CoreGraphics

/// Pure wayfinding math for the v4 board chrome (Phase 4 / crib §6–7):
/// fit-to-cards, the world↔minimap mapping, and offscreen-hint edge geometry.
///
/// All of it is view-independent (no AppKit), so it lives in TarmacKit beside
/// `BoardTransform` as a single, unit-tested source of truth. The AppKit
/// overlays (`ZoomControl` / `Minimap` / `OffscreenHints`) call into it.
public enum BoardWayfinding {
    // MARK: - Fit to cards (zoom control ⊡ fit; crib §6)

    /// The result of fitting all cards into the viewport: a target zoom plus the
    /// world-space center to point the viewport at.
    public struct Fit: Equatable {
        public var zoom: CGFloat
        public var center: CGPoint
        public init(zoom: CGFloat, center: CGPoint) {
            self.zoom = zoom
            self.center = center
        }
    }

    /// Bounding box of a set of world rects (the card frames). Returns nil for
    /// an empty set. The union is exact (no inset) — callers add fit margin.
    public static func boundingBox(of rects: [CGRect]) -> CGRect? {
        guard var box = rects.first else { return nil }
        for r in rects.dropFirst() { box = box.union(r) }
        return box
    }

    /// Fit-with-margin (crib §6): center the viewport on the cards' bounding box
    /// and pick the largest zoom that keeps the box inside `viewportSize` with a
    /// `margin` fraction of slack on every side (e.g. 0.1 = 10% padding). The
    /// zoom is clamped to `[minZoom, maxZoom]`. Returns nil when there are no
    /// cards (caller leaves the viewport unchanged).
    ///
    /// `viewportSize` is the on-screen board size in points; a degenerate (zero
    /// width/height) box falls back to `maxZoom` so a single tiny card doesn't
    /// blow the zoom up to infinity.
    public static func fit(
        cards: [CGRect],
        viewportSize: CGSize,
        margin: CGFloat,
        minZoom: CGFloat,
        maxZoom: CGFloat
    ) -> Fit? {
        guard let box = boundingBox(of: cards) else { return nil }
        let center = CGPoint(x: box.midX, y: box.midY)
        // Usable view extent after reserving `margin` on each side.
        let usableW = viewportSize.width * (1 - 2 * margin)
        let usableH = viewportSize.height * (1 - 2 * margin)
        guard usableW > 0, usableH > 0 else {
            return Fit(zoom: clamp(maxZoom, minZoom, maxZoom), center: center)
        }
        let zx = box.width > 0 ? usableW / box.width : maxZoom
        let zy = box.height > 0 ? usableH / box.height : maxZoom
        let zoom = clamp(min(zx, zy), minZoom, maxZoom)
        return Fit(zoom: zoom, center: center)
    }

    // MARK: - World ↔ minimap mapping (crib §6)

    /// Maps the world bounding box (cards + the current viewport rect) into the
    /// minimap's pixel box, preserving aspect ratio and centering, so the
    /// minimap shows the same proportions as the board. A `pad` (minimap-pixel)
    /// inset keeps rects off the minimap's edge.
    ///
    /// `scale` is uniform (min of the two axis ratios) and `offset` recenters the
    /// scaled content inside the minimap. `worldOrigin` is the world bbox origin.
    public struct MinimapMapping: Equatable {
        public var worldOrigin: CGPoint
        public var scale: CGFloat
        public var offset: CGPoint

        public init(worldOrigin: CGPoint, scale: CGFloat, offset: CGPoint) {
            self.worldOrigin = worldOrigin
            self.scale = scale
            self.offset = offset
        }

        /// world point → minimap point.
        public func toMinimap(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: (p.x - worldOrigin.x) * scale + offset.x,
                y: (p.y - worldOrigin.y) * scale + offset.y
            )
        }

        /// world rect → minimap rect.
        public func toMinimap(_ r: CGRect) -> CGRect {
            let o = toMinimap(CGPoint(x: r.minX, y: r.minY))
            return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
        }

        /// minimap point → world point (inverse; used for click-to-jump).
        public func toWorld(_ p: CGPoint) -> CGPoint {
            guard scale != 0 else { return worldOrigin }
            return CGPoint(
                x: (p.x - offset.x) / scale + worldOrigin.x,
                y: (p.y - offset.y) / scale + worldOrigin.y
            )
        }
    }

    /// Builds the aspect-preserving, centered mapping from `worldBox` into a
    /// `minimapSize` pixel box with `pad` pixels of inset on each side. A
    /// degenerate world box (zero extent) maps to the minimap center at scale 0
    /// — callers treat that as "nothing meaningful to draw".
    public static func minimapMapping(
        worldBox: CGRect,
        minimapSize: CGSize,
        pad: CGFloat
    ) -> MinimapMapping {
        let availW = max(0, minimapSize.width - 2 * pad)
        let availH = max(0, minimapSize.height - 2 * pad)
        let sx = worldBox.width > 0 ? availW / worldBox.width : 0
        let sy = worldBox.height > 0 ? availH / worldBox.height : 0
        // Uniform scale = the smaller ratio (so the box fits both axes).
        let scale: CGFloat
        if sx == 0 && sy == 0 {
            scale = 0
        } else if sx == 0 {
            scale = sy
        } else if sy == 0 {
            scale = sx
        } else {
            scale = min(sx, sy)
        }
        // Center the scaled content inside the available area.
        let scaledW = worldBox.width * scale
        let scaledH = worldBox.height * scale
        let offset = CGPoint(
            x: pad + (availW - scaledW) / 2,
            y: pad + (availH - scaledH) / 2
        )
        return MinimapMapping(worldOrigin: CGPoint(x: worldBox.minX, y: worldBox.minY), scale: scale, offset: offset)
    }

    // MARK: - Offscreen hints (crib §6)

    /// Which viewport edge a hint pins to, toward an offscreen card.
    public enum Edge: Equatable {
        case left, right, top, bottom

        /// The single-glyph direction arrow (crib §6: `→ ← ↑ ↓`).
        public var arrow: String {
            switch self {
            case .left: return "←"
            case .right: return "→"
            case .top: return "↑"
            case .bottom: return "↓"
            }
        }
    }

    /// A computed hint placement: which edge to pin to, and the *position along
    /// that edge* (the view-space coordinate of the card's center projected onto
    /// the edge, clamped into the viewport so the pill stays on-screen).
    public struct HintPlacement: Equatable {
        public var edge: Edge
        /// For a left/right edge this is the view-space y; for top/bottom, the x.
        public var along: CGFloat
        public init(edge: Edge, along: CGFloat) {
            self.edge = edge
            self.along = along
        }
    }

    /// True when `worldRect` is entirely outside `viewportWorldRect` is NOT what
    /// we want — a card counts as offscreen when its *center* is outside the
    /// visible world rect (so partially-visible cards near an edge still hint,
    /// matching the design's "toward the card" intent).
    public static func isOffscreen(cardCenterWorld c: CGPoint, viewportWorldRect vp: CGRect) -> Bool {
        !vp.contains(c)
    }

    /// Places a hint pill for an offscreen card. Given the card center in VIEW
    /// space and the visible view rect, pick the edge the card lies beyond
    /// (whichever axis is most out of bounds) and the clamped position along it.
    /// `inset` keeps the pill off the very corner. Returns nil when the center is
    /// inside the view rect (no hint needed).
    public static func hintPlacement(
        cardCenterView c: CGPoint,
        viewRect: CGRect,
        inset: CGFloat
    ) -> HintPlacement? {
        guard !viewRect.contains(c) else { return nil }
        // Distance the center sits beyond each edge (positive = outside).
        let beyondLeft = viewRect.minX - c.x
        let beyondRight = c.x - viewRect.maxX
        let beyondTop = viewRect.minY - c.y
        let beyondBottom = c.y - viewRect.maxY

        // Pick the edge with the largest positive overshoot.
        let candidates: [(Edge, CGFloat)] = [
            (.left, beyondLeft),
            (.right, beyondRight),
            (.top, beyondTop),
            (.bottom, beyondBottom),
        ]
        guard let (edge, _) = candidates.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) else {
            return nil
        }
        let loY = viewRect.minY + inset
        let hiY = viewRect.maxY - inset
        let loX = viewRect.minX + inset
        let hiX = viewRect.maxX - inset
        switch edge {
        case .left, .right:
            return HintPlacement(edge: edge, along: clamp(c.y, loY, hiY))
        case .top, .bottom:
            return HintPlacement(edge: edge, along: clamp(c.x, loX, hiX))
        }
    }

    // MARK: - Cascade placement (Phase 5b: ⌘T new terminal card)

    /// The top-left of a new card cascade-offset down-right from `base`, nudged
    /// by `(dx, dy)` until it does not (near-)coincide with any existing card's
    /// top-left (within `epsilon`) — so repeated ⌘T spawns stair-step instead of
    /// stacking on one spot. `existing` are the existing cards' top-left world
    /// points. The nudge is bounded so a pathological set can never loop forever.
    public static func cascadeOrigin(
        base: CGPoint,
        existing: [CGPoint],
        dx: CGFloat,
        dy: CGFloat,
        epsilon: CGFloat = 8
    ) -> CGPoint {
        var x = base.x + dx
        var y = base.y + dy
        var steps = 0
        while existing.contains(where: { abs($0.x - x) < epsilon && abs($0.y - y) < epsilon }) {
            x += dx
            y += dy
            steps += 1
            if steps > 1024 { break }
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: -

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(hi, max(lo, v))
    }
}
