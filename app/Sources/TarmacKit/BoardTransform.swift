import CoreGraphics

/// Pure world↔view transform for the v4 board (crib §5):
/// `view = (world − center) · zoom + viewportCenter`, inverted by
/// `world = (view − viewportCenter) / zoom + center`.
///
/// `center` is the viewport's world-space center (`board.cx/cy`); `viewportCenter`
/// is the board view's own view-space midpoint. Both spaces are top-down (the
/// `BoardView` is flipped). This lives in TarmacKit — separate from the AppKit
/// `BoardView` (an untestable executable target) — so the math is unit-testable
/// and there's a single source of truth.
public enum BoardTransform {
    public static func worldToView(
        _ p: CGPoint,
        zoom: CGFloat,
        center: CGPoint,
        viewportCenter: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (p.x - center.x) * zoom + viewportCenter.x,
            y: (p.y - center.y) * zoom + viewportCenter.y
        )
    }

    public static func viewToWorld(
        _ p: CGPoint,
        zoom: CGFloat,
        center: CGPoint,
        viewportCenter: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: (p.x - viewportCenter.x) / zoom + center.x,
            y: (p.y - viewportCenter.y) / zoom + center.y
        )
    }
}
