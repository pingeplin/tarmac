import CoreGraphics

/// The drag `tarmac dev resize <card> <w>x<h>` performs on a card's bottom-right
/// handle (spec 2609.0015, issue #166).
///
/// The delta is scaled INTO screen points by zoom, because the handle's own drag
/// divides by zoom to get back to world units; one left in world units resizes
/// by `1/zoom` of what was asked. The request is not clamped here: the card
/// applies its own minimum, and the reply reads the size back.
///
/// Points and deltas are in the board view's coordinates, which run top-down —
/// a taller card is a positive `dy`.
public enum DevResizeGrip {
    public enum Phase: Equatable, Sendable {
        case press, drag, release
    }

    public struct Step: Equatable, Sendable {
        public var phase: Phase
        public var location: CGPoint

        public init(phase: Phase, location: CGPoint) {
            self.phase = phase
            self.location = location
        }
    }

    public static func delta(from: CGSize, to: CGSize, zoom: CGFloat) -> CGVector {
        CGVector(dx: (to.width - from.width) * zoom, dy: (to.height - from.height) * zoom)
    }

    /// A left-button press on the handle, one drag to where the delta lands, and
    /// the release there.
    public static func drag(at handle: CGPoint, by delta: CGVector) -> [Step] {
        let end = CGPoint(x: handle.x + delta.dx, y: handle.y + delta.dy)
        return [
            Step(phase: .press, location: handle),
            Step(phase: .drag, location: end),
            Step(phase: .release, location: end),
        ]
    }

    /// `from` and `to` are the card's world size before and after the drag, read
    /// off the card, so `to` is where it LANDED rather than an echo of the request.
    public static func reply(from: CGSize, to: CGSize, delta: CGVector) -> JSONValue {
        [
            "from": ["w": .number(from.width), "h": .number(from.height)],
            "to": ["w": .number(to.width), "h": .number(to.height)],
            "delta_px": ["dx": .number(delta.dx), "dy": .number(delta.dy)],
        ]
    }
}
