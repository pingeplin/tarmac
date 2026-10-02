import AppKit
import TarmacKit

/// Where a press on one of a card's resize handles lands. It draws nothing
/// and has no area of its own: the card's hit test hands it the press whenever
/// the pointer is inside a handle zone, which keeps the zones a fixed size on
/// screen while the card's own coordinates scale with the board zoom.
@MainActor
final class CardResizeGrip: NSView {
    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) { onPress?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func mouseUp(with event: NSEvent) { onRelease?() }
}

/// There is no visible grip: the cursor is the only sign that a handle is there.
extension CardResizeGrip: HoverCursorProviding {
    /// Only over a doc. A terminal ignores a move that lands on a view above
    /// it; a web view does not, and the page's cursor would replace the
    /// handle's.
    var claimsPointerMoves: Bool { (superview as? CardView)?.docBody != nil }

    func hoverCursor(at windowPoint: NSPoint) -> NSCursor {
        guard let card = superview as? CardView, let board = card.superview,
              let handle = card.resizeHandle(at: board.convert(windowPoint, from: nil))
        else { return .arrow }
        switch CardHandles.cursor(for: handle) {
        case .diagonalDown: return .frameResize(position: .topLeft, directions: .all)
        case .diagonalUp: return .frameResize(position: .topRight, directions: .all)
        case .vertical: return .frameResize(position: .top, directions: .all)
        case .horizontal: return .frameResize(position: .left, directions: .all)
        }
    }
}

/// Drives a card's move and resize from the pointer events of its header and
/// its resize grip. The geometry, whether a gesture is a click, a move or a
/// resize, and which gesture is held are `CardGestureSlot`'s; this reads the
/// pointer, applies the frame and tells the card's listeners.
@MainActor
final class CardGestureTracker {
    private unowned let card: CardView
    private var slot = CardGestureSlot()

    init(card: CardView) {
        self.card = card
    }

    func headerPressed(_ event: NSEvent) {
        begin(.headerPress(at: pointer(event), frame: card.worldFrame.rect))
        card.onMoveBegan?(card)
    }

    func gripPressed(_ event: NSEvent) {
        let point = pointer(event)
        guard let handle = card.resizeHandle(at: point) else { return }
        begin(.handlePress(handle, at: point, frame: card.worldFrame.rect))
    }

    func dragged(_ event: NSEvent) {
        guard let frame = slot.drag(pointer: pointer(event), zoom: card.screenScale) else { return }
        card.worldFrame = CardFrame(rect: frame, z: card.worldFrame.z)
        card.setLifted(slot.isLifted)
        card.onFrameChanging?(card)
    }

    /// Ends the gesture, if one is held: on release, and when the release can
    /// no longer arrive.
    func end() {
        guard let outcome = slot.end() else { return }
        finish(outcome)
    }

    private func begin(_ gesture: CardGesture) {
        if let unreleased = slot.press(gesture) { finish(unreleased) }
        card.setLifted(slot.isLifted)
    }

    private func finish(_ outcome: CardGesture.Outcome) {
        card.setLifted(false)
        card.onGestureEnded?(card, outcome)
    }

    /// The pointer in the card's superview — screen points, y growing downward.
    private func pointer(_ event: NSEvent) -> CGPoint {
        card.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }
}
