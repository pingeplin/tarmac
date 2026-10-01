import CoreGraphics

/// The resize hit areas of a card: 20×20 corners and 6-thick edge strips that
/// stop 20 short of each corner. Sizes are SCREEN points measured from the
/// card's on-screen top-left, so the grab area stays the same size at every
/// zoom. A card with a close button has no top-right corner and a shorter top
/// strip, which leaves the button clickable.
public enum CardHandles {
    public static let cornerSize: CGFloat = 20
    public static let edgeThickness: CGFloat = 6
    /// How far the top strip stops short of the right edge beside a close button.
    public static let closeReserve: CGFloat = 32

    public enum Cursor: Equatable, Sendable {
        /// Top-left ↔ bottom-right.
        case diagonalDown
        /// Top-right ↔ bottom-left.
        case diagonalUp
        case vertical
        case horizontal
    }

    /// Paint order: where two zones overlap the later one is on top, and every
    /// corner is above every edge.
    private static let edges: [CardResize.Handle] = [.top, .right, .bottom, .left]
    private static let corners: [CardResize.Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    public static func handles(hasClose: Bool) -> [CardResize.Handle] {
        (edges + corners).filter { !(hasClose && $0 == .topRight) }
    }

    /// The zone of `handle` on a card `cardSize` big on screen, or nil when the
    /// card has no such handle or is too small to leave it any room.
    public static func zone(_ handle: CardResize.Handle, cardSize: CGSize, hasClose: Bool) -> CGRect? {
        let w = cardSize.width
        let h = cardSize.height
        let c = cornerSize
        let t = edgeThickness
        let rect: CGRect
        switch handle {
        case .topLeft: rect = CGRect(x: 0, y: 0, width: c, height: c)
        case .topRight:
            if hasClose { return nil }
            rect = CGRect(x: w - c, y: 0, width: c, height: c)
        case .bottomLeft: rect = CGRect(x: 0, y: h - c, width: c, height: c)
        case .bottomRight: rect = CGRect(x: w - c, y: h - c, width: c, height: c)
        case .top: rect = CGRect(x: c, y: 0, width: w - c - (hasClose ? closeReserve : c), height: t)
        case .bottom: rect = CGRect(x: c, y: h - t, width: w - 2 * c, height: t)
        case .left: rect = CGRect(x: 0, y: c, width: t, height: h - 2 * c)
        case .right: rect = CGRect(x: w - t, y: c, width: t, height: h - 2 * c)
        }
        // `size`, not `width`/`height`: those read back a negative extent as positive.
        return rect.size.width > 0 && rect.size.height > 0 ? rect : nil
    }

    /// The handle under `point`, the topmost where zones overlap.
    public static func handle(at point: CGPoint, cardSize: CGSize, hasClose: Bool) -> CardResize.Handle? {
        handles(hasClose: hasClose).last { handle in
            guard let zone = zone(handle, cardSize: cardSize, hasClose: hasClose) else { return false }
            return point.x >= zone.minX && point.x < zone.maxX && point.y >= zone.minY && point.y < zone.maxY
        }
    }

    public static func cursor(for handle: CardResize.Handle) -> Cursor {
        switch handle {
        case .topLeft, .bottomRight: return .diagonalDown
        case .topRight, .bottomLeft: return .diagonalUp
        case .top, .bottom: return .vertical
        case .left, .right: return .horizontal
        }
    }
}
