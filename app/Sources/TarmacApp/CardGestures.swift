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

/// Drives a card's move and resize from the pointer events of its header and
/// its resize grip. The geometry, and whether a release is a click, a move or
/// a resize, are `CardGesture`'s; this reads the pointer, applies the frame
/// and tells the card's listeners.
@MainActor
final class CardGestureTracker {
    private unowned let card: CardView
    private var gesture: CardGesture?

    init(card: CardView) {
        self.card = card
    }

    func headerPressed(_ event: NSEvent) {
        guard gesture == nil else { return }
        begin(.headerPress(at: pointer(event), frame: card.worldFrame.rect))
        card.onMoveBegan?(card)
    }

    func gripPressed(_ event: NSEvent) {
        let point = pointer(event)
        guard let handle = card.resizeHandle(at: point) else { return }
        begin(.handlePress(handle, at: point, frame: card.worldFrame.rect))
    }

    func dragged(_ event: NSEvent) {
        guard var gesture else { return }
        // The zoom is read on every step, so a pinch mid-drag keeps the card
        // under the pointer.
        let frame = gesture.frame(pointer: pointer(event), zoom: card.screenScale)
        self.gesture = gesture
        card.worldFrame = CardFrame(rect: frame, z: card.worldFrame.z)
        card.setLifted(gesture.isLifted)
        card.onFrameChanging?(card)
    }

    func released() {
        guard let gesture else { return }
        self.gesture = nil
        card.setLifted(false)
        card.onGestureEnded?(card, gesture.outcome)
    }

    private func begin(_ gesture: CardGesture) {
        guard self.gesture == nil else { return }
        self.gesture = gesture
        card.setLifted(gesture.isLifted)
    }

    /// The pointer in the card's superview — screen points, y growing downward.
    private func pointer(_ event: NSEvent) -> CGPoint {
        card.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
    }
}
