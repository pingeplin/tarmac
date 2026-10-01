import CoreGraphics

/// The board's zoom range; every path that changes the zoom clamps to it.
public enum BoardZoom {
    public static let min: CGFloat = 0.1
    public static let max: CGFloat = 3.0
}

/// How an HTML card's document is sized against the board zoom, and how a
/// wheel over its shield reaches it (specs 2607.0004, 2607.0006, 2609.0013).
///
/// A foreign document cannot be laid out ahead of time by the host, so it has
/// two modes. Magnify lays it out once at root zoom `magnifyK` in a box
/// `magnifyK` times the card's and shows that scaled by `zoom / magnifyK`.
/// Reveal lays it out at real screen pixels, scales it by `gestureScale` while
/// the zoom is changing, and sizes it again once the zoom has settled.
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

    public static func gestureScale(zoom: CGFloat, settledZoom: CGFloat) -> CGFloat {
        zoom / settledZoom
    }

    /// A screen-point wheel delta in the document's own layout units: one
    /// screen point is `1 / zoom` of a unit under magnify and one unit in reveal.
    public static func scrollDelta(_ deltaPx: CGFloat, zoom: CGFloat, magnify: Bool) -> CGFloat {
        magnify && zoom > 0 ? deltaPx / zoom : deltaPx
    }

    public struct Quantized: Equatable, Sendable {
        public var step: Int
        public var carry: Double

        public init(step: Int, carry: Double) {
            self.step = step
            self.carry = carry
        }
    }

    /// A relayed delta as a whole-pixel step plus the residue for the next
    /// event. A fractional `scrollBy` leaves an unpainted band; rounding alone
    /// would stall a slow trackpad, whose every delta rounds to zero.
    public static func quantizeScrollDelta(_ delta: Double, carry: Double) -> Quantized {
        let total = delta + carry
        let step = total.roundedHalfUp
        return Quantized(step: Int(step), carry: total - step)
    }

    public struct ScrollStep: Equatable, Sendable {
        public var dx: Int
        public var dy: Int

        public init(dx: Int, dy: Int) {
            self.dx = dx
            self.dy = dy
        }
    }

    /// One shielded card's wheel relay: it holds each axis's residue between
    /// events.
    public struct ScrollRelay: Sendable {
        private var carryX = 0.0
        private var carryY = 0.0

        public init() {}

        /// The whole-pixel step to send, or nil when neither axis moved one.
        /// The residues are kept either way.
        public mutating func step(dx: Double, dy: Double) -> ScrollStep? {
            let x = CardZoom.quantizeScrollDelta(dx, carry: carryX)
            let y = CardZoom.quantizeScrollDelta(dy, carry: carryY)
            carryX = x.carry
            carryY = y.carry
            return x.step == 0 && y.step == 0 ? nil : ScrollStep(dx: x.step, dy: y.step)
        }
    }
}
