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

/// A board's viewport: zoom and world-space center. The view layer holds the
/// wire type it is persisted as, which is also what the kit's board math takes.
typealias Viewport = BoardViewport

extension BoardViewport {
    /// The zoom is clamped to this range on every path that changes it.
    static let minZoom = BoardZoom.min
    static let maxZoom = BoardZoom.max

    /// The viewport a board opens at when none was persisted.
    static let `default` = Placement.openingViewport

    var center: CGPoint { CGPoint(x: cx, y: cy) }
}
