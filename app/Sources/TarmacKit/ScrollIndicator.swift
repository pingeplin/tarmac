import CoreGraphics

/// The one scroll thumb every card kind wears: where it sits on its track,
/// its frame on screen, and when it shows (spec 2610.0003). Lengths are world
/// units, as the header's 30 is, unless a frame says otherwise.
public enum ScrollIndicator {
    public static let width: CGFloat = 6
    /// From the body's right edge, and from its top.
    public static let inset: CGFloat = 2
    public static let minLength: CGFloat = 24

    public struct Thumb: Equatable, Sendable {
        public var y: CGFloat
        public var length: CGFloat

        public init(y: CGFloat, length: CGFloat) {
            self.y = y
            self.length = length
        }
    }

    /// The thumb on a track `track` long, in the track's units.
    public static func thumb(_ metrics: ScrollMetrics?, track: CGFloat) -> Thumb? {
        guard let metrics, metrics.overflows, track >= minLength else { return nil }
        let length = max(minLength, track * metrics.visible / metrics.total)
        return Thumb(y: (track - length) * metrics.offset / (metrics.total - metrics.visible), length: length)
    }

    /// The thumb's frame on screen, in the coordinates `body` — the body's
    /// on-screen rect as it shows, `CardBox.Screen.shownBody` — is given in.
    /// `covered` is the height an overlay of the body's own hides at its
    /// bottom.
    ///
    /// The track starts `inset` below the body's top and ends clear of the
    /// card's rounded bottom corner, or `inset` above the overlay where that
    /// is higher. Each term lands on a whole device pixel, and `x` leaves room
    /// for the width as it is snapped.
    public static func frame(_ metrics: ScrollMetrics?, body: CGRect, covered: CGFloat, scale: CardScale) -> CGRect? {
        let track = body.height / scale.zoom - inset - max(CardBox.cornerRadius, covered + inset)
        guard let thumb = thumb(metrics, track: track) else { return nil }
        let width = scale.snapped(width)
        return CGRect(
            x: scale.aligned(body.maxX - scale.length(inset) - width),
            y: scale.aligned(body.minY + scale.length(inset + thumb.y)),
            width: width,
            height: scale.snapped(thumb.length)
        )
    }

    /// When the thumb shows: from a wheel on the card until `holdMs` after the
    /// last one, then a fade of `fadeMs`.
    public struct Visibility: Equatable, Sendable {
        public static let holdMs: UInt64 = 1000
        public static let fadeMs: UInt64 = 200

        private var wheeledAtMs: UInt64?

        public init() {}

        public mutating func wheeled(atMs now: UInt64) {
            wheeledAtMs = now
        }

        /// The card was deselected: the thumb goes at once, with no fade.
        public mutating func reset() {
            wheeledAtMs = nil
        }

        public func alpha(atMs now: UInt64) -> CGFloat {
            guard let wheeledAtMs else { return 0 }
            guard now > wheeledAtMs, now - wheeledAtMs > Self.holdMs else { return 1 }
            let fadedMs = now - wheeledAtMs - Self.holdMs
            return fadedMs < Self.fadeMs ? 1 - CGFloat(fadedMs) / CGFloat(Self.fadeMs) : 0
        }
    }
}
