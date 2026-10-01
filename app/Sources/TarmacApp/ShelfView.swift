import AppKit
import TarmacKit

/// One shelf entry (crib §6): a parked, open-but-unplaced doc.
struct ShelfItem: Equatable {
    var path: String
    var basename: String
    var repoColor: Int?
    var fallbackName: String
    var unread: Bool
}

/// The shelf (crib §6 / migration-plan Phase 3): a top-left overlay holding
/// open-but-unplaced docs as chips. Replaces the retired dock rail. Hidden when
/// empty. Click a chip to peek it; drag a chip onto the board to land a card.
///
/// Geometry (crib §6): left 12 / top 12; bg2, 1px line border, radius 9,
/// padding 5px 9px; a faint 9.5px-mono `SHELF` label, then chips.
@MainActor
final class ShelfView: NSView {
    /// A chip was clicked (peek the doc).
    var onChipClick: ((String) -> Void)?
    /// A chip was dragged onto the board and released at `windowPoint` (window
    /// coords). The controller converts to a world position and lands a card.
    var onChipDropped: ((String, NSPoint) -> Void)?

    private let label = NSTextField(labelWithString: "SHELF")
    private var chips: [ShelfChipView] = []
    private var items: [ShelfItem] = []

    private static let padX: CGFloat = 9
    private static let padY: CGFloat = 5
    private static let gap: CGFloat = 6

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 9

        label.font = Theme.mono(9.5)
        label.textColor = Theme.faint
        addSubview(label)

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(items: [ShelfItem]) {
        guard items != self.items else { return }
        self.items = items
        for chip in chips { chip.removeFromSuperview() }
        chips = items.map { item in
            let chip = ShelfChipView(item: item)
            chip.onClick = { [weak self] in self?.onChipClick?(item.path) }
            chip.onDrop = { [weak self] windowPoint in self?.onChipDropped?(item.path, windowPoint) }
            addSubview(chip)
            return chip
        }
        isHidden = items.isEmpty
        needsLayout = true
        sizeToContents()
    }

    /// Resizes the overlay to wrap its label + chips (single row).
    private func sizeToContents() {
        guard !items.isEmpty else { return }
        let labelW = label.fittedSize.width
        var w = Self.padX + labelW
        let h = max(label.fittedSize.height, chips.map { $0.intrinsicContentSize.height }.max() ?? 0)
        for chip in chips {
            w += Self.gap + chip.intrinsicContentSize.width
        }
        w += Self.padX
        let totalH = Self.padY * 2 + h
        frame = NSRect(x: 12, y: 12, width: w.rounded(), height: totalH.rounded())
    }

    override func layout() {
        super.layout()
        let contentH = bounds.height - Self.padY * 2
        let labelSize = label.fittedSize
        label.frame = NSRect(
            x: Self.padX,
            y: (Self.padY + (contentH - labelSize.height) / 2).rounded(),
            width: labelSize.width,
            height: labelSize.height
        )
        var x = label.frame.maxX + Self.gap
        for chip in chips {
            let size = chip.intrinsicContentSize
            chip.frame = NSRect(
                x: x.rounded(),
                y: (Self.padY + (contentH - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            x += size.width + Self.gap
        }
    }
}

/// A shelf chip (crib §6): bg1, 1px line-soft border, radius 6, padding 3px 8px,
/// 10px mono muted; content = a 7px repo dot + basename, plus an agent unread
/// dot when the doc is unread. Owns its mouse: a click peeks; a drag past a
/// small threshold reports a drop (for landing a card on the board).
@MainActor
final class ShelfChipView: NSView {
    var onClick: (() -> Void)?
    var onDrop: ((NSPoint) -> Void)?

    private let repoDot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let item: ShelfItem
    private var size: NSSize = .zero

    private var mouseDownAt: NSPoint?
    private var dragging = false

    private static let padX: CGFloat = 8
    private static let padY: CGFloat = 3
    private static let gap: CGFloat = 6
    private static let dotSize: CGFloat = 7
    private static let unreadSize: CGFloat = 5

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg1.cgColor
        layer?.borderColor = Theme.lineSoft.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        repoDot.wantsLayer = true
        repoDot.layer?.cornerRadius = Self.dotSize / 2
        repoDot.layer?.backgroundColor =
            Theme.repoColor(index: item.repoColor, fallbackName: item.fallbackName).cgColor
        addSubview(repoDot)

        nameLabel.font = Theme.mono(10)
        nameLabel.textColor = Theme.muted
        nameLabel.stringValue = item.basename
        addSubview(nameLabel)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = Self.unreadSize / 2
        unreadDot.layer?.backgroundColor = Theme.agent.cgColor
        unreadDot.isHidden = !item.unread
        addSubview(unreadDot)

        let nameW = nameLabel.fittedSize.width
        let unreadW = item.unread ? Self.gap + Self.unreadSize : 0
        let w = Self.padX + Self.dotSize + Self.gap + nameW + unreadW + Self.padX
        let h = Self.padY * 2 + max(Self.dotSize, nameLabel.fittedSize.height)
        size = NSSize(width: w.rounded(), height: h.rounded())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x = Self.padX
        repoDot.frame = NSRect(x: x, y: ((h - Self.dotSize) / 2).rounded(), width: Self.dotSize, height: Self.dotSize)
        x += Self.dotSize + Self.gap
        let nameSize = nameLabel.fittedSize
        nameLabel.frame = NSRect(x: x, y: ((h - nameSize.height) / 2).rounded(), width: nameSize.width, height: nameSize.height)
        x += nameSize.width
        if !unreadDot.isHidden {
            x += Self.gap
            unreadDot.frame = NSRect(x: x, y: ((h - Self.unreadSize) / 2).rounded(), width: Self.unreadSize, height: Self.unreadSize)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let d = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        if d > 4 { dragging = true }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownAt = nil; dragging = false }
        if dragging {
            onDrop?(event.locationInWindow)
        } else {
            onClick?()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
