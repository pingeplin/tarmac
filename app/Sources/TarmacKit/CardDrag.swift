import CoreGraphics

/// A header press on a card. The card follows the pointer from the first
/// point of travel, but the press only counts as a MOVE — the thing that
/// lifts the card and, on release, is committed — once the pointer has gone
/// more than `threshold` screen points from where it went down on either
/// axis. Short of that it stays a click, which only selects.
public struct CardDrag: Equatable, Sendable {
    public static let threshold: CGFloat = 3

    /// Where the pointer went down, in screen points (y grows downward).
    public let pressPoint: CGPoint
    /// The card's world origin at that moment.
    public let startOrigin: CGPoint
    /// Latched: coming back within the threshold does not undo a move.
    public private(set) var moved = false

    public init(pressPoint: CGPoint, startOrigin: CGPoint) {
        self.pressPoint = pressPoint
        self.startOrigin = startOrigin
    }

    /// The card's world origin with the pointer at `pointer`, at board `zoom`.
    public mutating func origin(pointer: CGPoint, zoom: CGFloat) -> CGPoint {
        let dx = pointer.x - pressPoint.x
        let dy = pointer.y - pressPoint.y
        if abs(dx) > Self.threshold || abs(dy) > Self.threshold { moved = true }
        return CGPoint(x: startOrigin.x + dx / zoom, y: startOrigin.y + dy / zoom)
    }
}
