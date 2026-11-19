import AppKit

/// The bar between the inbox list and its preview pane (spec 2611.0018 D6,
/// D12): a drag resizes the pane, a double-click resets it. A press gives it
/// the focus in the panel's state; it never takes first responder, so the
/// panel keeps the keys.
@MainActor
final class InboxSplitGrip: NSView {
    static let height: CGFloat = 9
    private static let handle = NSSize(width: 28, height: 2)

    /// The click count of a press.
    var onPress: ((Int) -> Void)?
    /// How far the grip is from where the press was, in screen points; up is
    /// positive.
    var onDrag: ((CGFloat) -> Void)?
    var onRelease: (() -> Void)?

    var focused = false {
        didSet { if focused != oldValue { needsDisplay = true } }
    }
    private var hovered = false
    private var pressY: CGFloat?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg1.setFill()
        bounds.fill()
        Theme.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let lit = hovered || focused || pressY != nil
        (lit ? Theme.agent : Theme.line).setFill()
        let size = Self.handle
        NSBezierPath(
            roundedRect: NSRect(
                x: ((bounds.width - size.width) / 2).rounded(), y: 4, width: size.width, height: size.height
            ),
            xRadius: 1, yRadius: 1
        ).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressY = event.locationInWindow.y
        needsDisplay = true
        onPress?(event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressY else { return }
        onDrag?(event.locationInWindow.y - pressY)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressY != nil else { return }
        pressY = nil
        needsDisplay = true
        onRelease?()
    }

    /// The panel hid mid-drag: a hidden view gets no `mouseUp`.
    func cancelPress() {
        guard pressY != nil else { return }
        pressY = nil
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
}
