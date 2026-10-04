import CoreGraphics

/// What a point on a card is, in the order a press is given away: the scroll
/// thumb while it can be grabbed, then a resize handle, then the content.
public enum CardHit: Equatable, Sendable {
    case thumb
    case handle(CardResize.Handle)
    case content

    /// `point` and `thumb` are in one coordinate space; `thumb` is nil when
    /// none is laid out.
    public static func at(
        _ point: CGPoint, thumb: CGRect?, grabbable: Bool, handle: CardResize.Handle?
    ) -> CardHit {
        if grabbable, let thumb,
           point.x >= thumb.minX, point.x < thumb.maxX, point.y >= thumb.minY, point.y < thumb.maxY {
            return .thumb
        }
        return handle.map(CardHit.handle) ?? .content
    }
}
