import AppKit

/// A text run of an overlay panel (the switcher, the inbox). Clicks go to
/// whatever holds it.
@MainActor
final class OverlayLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A clickable row of an overlay panel (spec 2611.0018 D10): `bg3` and a
/// `focus-border` outline while it is selected, a quieter `rowHover` while it
/// is hovered, a pointing hand, and a click that goes to `onClick` with its
/// click count.
@MainActor
class OverlayRowView: NSView {
    var onClick: ((Int) -> Void)?
    var selected = false {
        didSet { paint() }
    }
    private(set) var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func paint() {
        layer?.backgroundColor = (selected ? Theme.bg3 : hovered ? Theme.rowHover : NSColor.clear).cgColor
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = Theme.focusBorder.cgColor
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
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        paint()
    }

    override func mouseDown(with event: NSEvent) { onClick?(event.clickCount) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

extension CGFloat {
    /// The top of a box `height` tall centred, on a whole point, in a line
    /// `line` tall that starts at `top`.
    func centered(_ height: CGFloat, top: CGFloat = 0) -> CGFloat {
        top + ((self - height) / 2).rounded()
    }
}
