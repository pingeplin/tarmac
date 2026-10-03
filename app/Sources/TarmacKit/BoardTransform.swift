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

    public static func clampedZoom(_ zoom: CGFloat, limits: ClosedRange<CGFloat>) -> CGFloat {
        min(limits.upperBound, max(limits.lowerBound, zoom))
    }

    /// `viewport` with its zoom multiplied by `factor` and held to `limits`,
    /// and its center moved so the world point under the view point `anchor`
    /// stays where it is on screen. A zoom already at a limit comes back as it
    /// went in, rather than re-deriving a center that could drift.
    public static func zoomed(
        _ viewport: BoardViewport,
        by factor: CGFloat,
        about anchor: CGPoint,
        viewportCenter: CGPoint,
        limits: ClosedRange<CGFloat>
    ) -> BoardViewport {
        let zoom = clampedZoom(viewport.zoom * factor, limits: limits)
        guard zoom != viewport.zoom else { return viewport }
        let world = viewToWorld(
            anchor, zoom: viewport.zoom, center: CGPoint(x: viewport.cx, y: viewport.cy), viewportCenter: viewportCenter
        )
        return BoardViewport(
            zoom: zoom,
            cx: world.x - (anchor.x - viewportCenter.x) / zoom,
            cy: world.y - (anchor.y - viewportCenter.y) / zoom
        )
    }

    /// `viewport` after the content has travelled `travel` screen points: the
    /// content follows the wheel, so the center goes the other way.
    public static func panned(_ viewport: BoardViewport, by travel: CGVector) -> BoardViewport {
        BoardViewport(
            zoom: viewport.zoom,
            cx: viewport.cx - travel.dx / viewport.zoom,
            cy: viewport.cy - travel.dy / viewport.zoom
        )
    }
}
