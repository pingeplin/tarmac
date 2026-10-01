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
