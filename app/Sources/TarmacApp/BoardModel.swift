import CoreGraphics
import Foundation
import TarmacKit

/// A card's identity on a board: a terminal card by its daemon `term_id`, a
/// doc card by its registry path.
enum CardID: Hashable {
    case term(String)
    case doc(String)
}

/// Where a card is in the world: `x,y,w,h` in world units and `z` for
/// stacking, higher in front. Persisted as `LayoutTile.x/y/w/h/z`.
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

/// A board's viewport: zoom and world-space center. The view layer's CGFloat
/// twin of the wire `BoardViewport`, which it is persisted as.
struct Viewport: Equatable {
    var zoom: CGFloat
    var cx: CGFloat
    var cy: CGFloat

    /// The zoom is clamped to this range on every path that changes it.
    static let minZoom = BoardZoom.min
    static let maxZoom = BoardZoom.max

    /// The viewport a board opens at when none was persisted.
    static let `default` = Viewport(Placement.openingViewport)
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
