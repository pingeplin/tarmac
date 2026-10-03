import CoreGraphics

/// Viewport culling: a card more than one full viewport off-screen is hidden so it
/// stops compositing — but the card is kept ALIVE, never removed, so a terminal
/// keeps receiving PTY output and a doc keeps its scroll. This is just the pure
/// predicate; the board toggles visibility on the pan/zoom hot path.
public enum Cull {
    /// Default margin, in full viewports per side.
    public static let marginViewports: CGFloat = 1

    /// The world-space rectangle that is on screen (the `viewSize` viewport
    /// un-projected at `zoom` around `center`), grown by `marginViewports` full
    /// viewports on every side. A card intersecting it stays visible.
    public static func visibleWorldRect(
        zoom: CGFloat,
        center: CGPoint,
        viewSize: CGSize,
        marginViewports: CGFloat = Cull.marginViewports
    ) -> CGRect {
        let visibleWidth = viewSize.width / zoom
        let visibleHeight = viewSize.height / zoom
        let halfWidth = visibleWidth / 2 + marginViewports * visibleWidth
        let halfHeight = visibleHeight / 2 + marginViewports * visibleHeight
        return CGRect(
            x: center.x - halfWidth,
            y: center.y - halfHeight,
            width: 2 * halfWidth,
            height: 2 * halfHeight
        )
    }

    /// Whether a card at world `frame` should be rendered. A zero-area viewport
    /// (a hidden board) hides every card: it degenerates the visible rect to a
    /// point at `center`, which the strict overlap would still keep intersecting
    /// the one card that strictly contains it (#104).
    public static func isCardVisible(
        frame: CGRect,
        zoom: CGFloat,
        center: CGPoint,
        viewSize: CGSize,
        marginViewports: CGFloat = Cull.marginViewports
    ) -> Bool {
        if viewSize.width == 0 || viewSize.height == 0 { return false }
        return Placement.rectsIntersect(
            frame,
            visibleWorldRect(zoom: zoom, center: center, viewSize: viewSize, marginViewports: marginViewports)
        )
    }
}
