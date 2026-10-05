import CoreGraphics

/// The one scroll thumb every card kind wears: where it sits on its track,
/// its frame on screen, and when it shows (spec 2610.0003). Lengths are world
/// units, as the header's 30 is, unless a frame says otherwise.
public enum ScrollIndicator {
    public static let width: CGFloat = 10
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
        guard let thumb = thumb(metrics, track: track(body: body, covered: covered, scale: scale)) else { return nil }
        let width = scale.snapped(width)
        return CGRect(
            x: scale.aligned(body.maxX - scale.length(inset) - width),
            y: scale.aligned(body.minY + scale.length(inset + thumb.y)),
            width: width,
            height: scale.snapped(thumb.length)
        )
    }

    /// The track's length, in world units.
    static func track(body: CGRect, covered: CGFloat, scale: CardScale) -> CGFloat {
        body.height / scale.zoom - inset - max(CardBox.cornerRadius, covered + inset)
    }

    /// When the thumb shows: from a wheel on the card until `holdMs` after the
    /// last one, then a fade of `fadeMs`. A pointer over the showing thumb, or
    /// a press on it, holds it at full; when the last of the two lets go the
    /// hold starts again.
    public struct Visibility: Equatable, Sendable {
        public static let holdMs: UInt64 = 1000
        public static let fadeMs: UInt64 = 200

        private var heldFromMs: UInt64?
        private var pointerOver = false
        private var isPressed = false

        public init() {}

        public mutating func wheeled(atMs now: UInt64) {
            heldFromMs = now
        }

        /// A pointer over a thumb that is not showing is not over it: hover
        /// alone shows nothing.
        public mutating func pointer(over: Bool, atMs now: UInt64) {
            guard over != pointerOver else { return }
            if over {
                guard grabbable(atMs: now) else { return }
                pointerOver = true
            } else {
                pointerOver = false
                if !isPressed { heldFromMs = now }
            }
        }

        /// Taken whatever the alpha: the hit rule is the gate.
        public mutating func pressed(atMs now: UInt64) {
            isPressed = true
        }

        public mutating func released(atMs now: UInt64) {
            guard isPressed else { return }
            isPressed = false
            if !pointerOver { heldFromMs = now }
        }

        /// The card was deselected: the thumb goes at once, with no fade.
        public mutating func reset() {
            self = Visibility()
        }

        public func alpha(atMs now: UInt64) -> CGFloat {
            if pointerOver || isPressed { return 1 }
            guard let heldFromMs else { return 0 }
            guard now > heldFromMs, now - heldFromMs > Self.holdMs else { return 1 }
            let fadedMs = now - heldFromMs - Self.holdMs
            return fadedMs < Self.fadeMs ? 1 - CGFloat(fadedMs) / CGFloat(Self.fadeMs) : 0
        }

        /// A fading thumb can still be caught.
        public func grabbable(atMs now: UInt64) -> Bool {
            alpha(atMs: now) > 0
        }

        /// The instant the hold ends, which is past once the fade has begun;
        /// nil while the thumb is held, and when it does not show.
        public func fadeStartsAtMs(atMs now: UInt64) -> UInt64? {
            guard !pointerOver, !isPressed, let heldFromMs, grabbable(atMs: now) else { return nil }
            let (end, overflowed) = heldFromMs.addingReportingOverflow(Self.holdMs)
            return overflowed ? .max : end
        }
    }
}
