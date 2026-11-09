import CoreGraphics

/// The drag `tarmac dev resize <card> <w>x<h> [--handle <handle>]` performs on
/// one of a card's handles, the bottom-right one unless named (spec 2609.0015,
/// issues #166 and #296).
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

    private static let names: [CardResize.Handle: String] = [
        .topLeft: "top-left", .top: "top", .topRight: "top-right", .right: "right",
        .bottomRight: "bottom-right", .bottom: "bottom", .bottomLeft: "bottom-left", .left: "left",
    ]

    /// The handle a `--handle` name stands for.
    public static func handle(named name: String) -> CardResize.Handle? {
        names.first { $0.value == name }?.key
    }

    public static func name(of handle: CardResize.Handle) -> String {
        names[handle] ?? ""
    }

    /// Where the press goes: the middle of `handle`'s zone on a card whose
    /// on-screen frame is `cardFrame` — the zone the card's own hit test uses —
    /// or nil when the card has no such handle.
    public static func pressPoint(_ handle: CardResize.Handle, of cardFrame: CGRect, hasClose: Bool) -> CGPoint? {
        CardHandles.zone(handle, cardSize: cardFrame.size, hasClose: hasClose).map {
            CGPoint(x: cardFrame.minX + $0.midX, y: cardFrame.minY + $0.midY)
        }
    }

    /// A left or top handle grows the card when dragged left or up, and an edge
    /// handle drags along its own axis only.
    public static func delta(from: CGSize, to: CGSize, zoom: CGFloat, handle: CardResize.Handle) -> CGVector {
        let dx = (to.width - from.width) * zoom
        let dy = (to.height - from.height) * zoom
        return CGVector(
            dx: [.top, .bottom].contains(handle) ? 0 : [.topLeft, .bottomLeft, .left].contains(handle) ? -dx : dx,
            dy: [.left, .right].contains(handle) ? 0 : [.topLeft, .topRight, .top].contains(handle) ? -dy : dy
        )
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
    public static func reply(from: CGSize, to: CGSize, delta: CGVector, handle: CardResize.Handle) -> JSONValue {
        [
            "from": ["w": .number(from.width), "h": .number(from.height)],
            "to": ["w": .number(to.width), "h": .number(to.height)],
            "delta_px": ["dx": .number(delta.dx), "dy": .number(delta.dy)],
            "handle": .string(name(of: handle)),
        ]
    }
}
