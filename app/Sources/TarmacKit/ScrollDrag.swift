import CoreGraphics

/// A drag of the scroll thumb: where on the thumb the press landed, and the
/// offset each pointer position asks the content for (spec 2610.0004).
public struct ScrollDrag: Equatable, Sendable {
    /// How far below the thumb's top the press landed, in screen points.
    public let grab: CGFloat

    /// `thumb` is the thumb's frame as drawn at the press, and `pointerY` is
    /// in the coordinates that frame is in.
    public init(pointerY: CGFloat, thumb: CGRect) {
        grab = pointerY - thumb.minY
    }

    /// The offset that puts the thumb's top `grab` above the pointer, on the
    /// track as `ScrollIndicator.frame` lays it out from these arguments; nil
    /// when there is no thumb, or no room for it to move.
    public func offset(
        pointerY: CGFloat, metrics: ScrollMetrics?, body: CGRect, covered: CGFloat, scale: CardScale
    ) -> Double? {
        let track = ScrollIndicator.track(body: body, covered: covered, scale: scale)
        guard let metrics, let thumb = ScrollIndicator.thumb(metrics, track: track) else { return nil }
        let free = track - thumb.length
        guard free > 0 else { return nil }
        let top = (pointerY - grab - body.minY) / scale.zoom - ScrollIndicator.inset
        return Double(min(max(top, 0), free) / free) * (metrics.total - metrics.visible)
    }
}
