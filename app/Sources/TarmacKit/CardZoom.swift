import CoreGraphics

/// The board's zoom range; every path that changes the zoom clamps to it.
public enum BoardZoom {
    public static let min: CGFloat = 0.1
    public static let max: CGFloat = 3.0
}

/// How an HTML card's document is sized against the board zoom, and what a
/// wheel's travel is in its units (specs 2607.0004, 2607.0006, 2609.0013,
/// 2610.0002).
///
/// A foreign document cannot be laid out ahead of time by the host, so it has
/// two modes. Magnify lays it out once at root zoom `magnifyK` in a box
/// `magnifyK` times the card's and shows that scaled by `zoom / magnifyK`.
/// Reveal lays it out at real screen pixels and sizes it again once the zoom
/// has settled; while the zoom is changing the card's own stretch carries it.
public enum CardZoom {
    /// Frozen: a root zoom that followed the board would lay the document out
    /// again at each value, and WebKit does not scale glyph advances linearly
    /// across them, so wrap points would move. At least `BoardZoom.max`, so the
    /// outer scale is always a down-scale.
    public static let magnifyK: CGFloat = 3

    /// How long the zoom has to hold still before a reveal document is sized again.
    public static let settleDelay: Double = 0.15

    public static func iframePx(frame: CGSize, zoom: CGFloat) -> CGSize {
        CGSize(width: (frame.width * zoom).roundedHalfUp, height: (frame.height * zoom).roundedHalfUp)
    }

    /// Document units per screen point of wheel travel: `magnifyK / zoom`
    /// under magnify, 1 in reveal and for a zoom that is not finite and positive.
    public static func wheelScale(zoom: CGFloat, magnify: Bool) -> CGFloat {
        magnify && zoom.isFinite && zoom > 0 ? magnifyK / zoom : 1
    }

    public struct Quantized: Equatable, Sendable {
        public var step: Int
        public var carry: Double

        public init(step: Int, carry: Double) {
            self.step = step
            self.carry = carry
        }
    }

    /// A delta as a whole-unit step plus the residue for the next event. A
    /// wheel event's point delta is an integer field; rounding alone would
    /// stall a slow trackpad, whose every delta rounds to zero.
    public static func quantizeScrollDelta(_ delta: Double, carry: Double) -> Quantized {
        let total = delta + carry
        let step = total.roundedHalfUp
        return Quantized(step: Int(step), carry: total - step)
    }
}
