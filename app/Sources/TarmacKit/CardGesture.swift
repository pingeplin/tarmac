import CoreGraphics

/// One pointer gesture on a card, from press to release: a header press that
/// may become a move, or a resize from one of the handles. Pointer positions
/// are screen points (y grows downward); frames are world units.
public struct CardGesture: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// A header press that never travelled past the drag threshold: it
        /// selected the card and commits nothing.
        case click
        case move
        case resize
    }

    private enum Kind: Equatable, Sendable {
        case move(CardDrag)
        case resize(CardResize.Handle, pressPoint: CGPoint)
    }

    private var kind: Kind
    private let startFrame: CGRect

    public static func headerPress(at pressPoint: CGPoint, frame: CGRect) -> CardGesture {
        CardGesture(kind: .move(CardDrag(pressPoint: pressPoint, startOrigin: frame.origin)), startFrame: frame)
    }

    public static func handlePress(_ handle: CardResize.Handle, at pressPoint: CGPoint, frame: CGRect) -> CardGesture {
        CardGesture(kind: .resize(handle, pressPoint: pressPoint), startFrame: frame)
    }

    /// The card's world frame with the pointer at `pointer`, at board `zoom`.
    public mutating func frame(pointer: CGPoint, zoom: CGFloat) -> CGRect {
        switch kind {
        case .move(var drag):
            let origin = drag.origin(pointer: pointer, zoom: zoom)
            kind = .move(drag)
            return CGRect(origin: origin, size: startFrame.size)
        case .resize(let handle, let pressPoint):
            let travel = CGVector(dx: (pointer.x - pressPoint.x) / zoom, dy: (pointer.y - pressPoint.y) / zoom)
            return CardResize.frame(from: startFrame, dragging: handle, by: travel)
        }
    }

    /// Whether the card shows as picked up: a resize from the press on, a
    /// header press only once it has become a move.
    public var isLifted: Bool {
        outcome != .click
    }

    /// What releasing the pointer now amounts to.
    public var outcome: Outcome {
        switch kind {
        case .move(let drag): return drag.moved ? .move : .click
        case .resize: return .resize
        }
    }
}

/// The one gesture a card can be in. A gesture ends on release, and the same
/// way when it is cut short: the card is removed or leaves its window with the
/// pointer still down, so the release never arrives.
public struct CardGestureSlot: Equatable, Sendable {
    private var held: CardGesture?

    public init() {}

    /// Holds `gesture`. A gesture still held from before never saw its
    /// release; what it amounted to is returned, for the caller to end it first.
    public mutating func press(_ gesture: CardGesture) -> CardGesture.Outcome? {
        defer { held = gesture }
        return held?.outcome
    }

    /// The card's world frame with the pointer at `pointer`, or nil with no
    /// gesture held.
    public mutating func drag(pointer: CGPoint, zoom: CGFloat) -> CGRect? {
        held?.frame(pointer: pointer, zoom: zoom)
    }

    /// Lets go of the held gesture and returns what it amounted to, or nil
    /// with none held.
    public mutating func end() -> CardGesture.Outcome? {
        defer { held = nil }
        return held?.outcome
    }

    public var isLifted: Bool {
        held?.isLifted ?? false
    }
}
