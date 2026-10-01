import AppKit

/// The ⌥Tab readout: a row of chips at the top center of the board, one per
/// live terminal in cycle order with the new prime highlighted. It hides a
/// moment after the last ⌥Tab and never takes a click.
@MainActor
final class CycleHUD: NSView {
    /// Distance below the board's top edge.
    static let topInset: CGFloat = 12

    private static let holdMs = 1100
    private static let border: CGFloat = 1
    private static let padX: CGFloat = 8
    private static let padY: CGFloat = 4
    private static let itemGap: CGFloat = 4

    private var items: [CycleHUDItem] = []
    private var hideWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg3.withAlphaComponent(0.92).cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = Self.border
        layer?.cornerRadius = 8
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `labels` with `activeIndex` highlighted and restarts the hide
    /// timer.
    func show(labels: [String], activeIndex: Int) {
        for item in items { item.removeFromSuperview() }
        items = labels.enumerated().map { index, text in
            let item = CycleHUDItem(text: text, active: index == activeIndex)
            addSubview(item)
            return item
        }
        isHidden = false
        sizeToContents()
        // Centered now, not at the host's next layout pass, so the HUD never
        // flashes at the corner first.
        if let host = superview {
            frame = NSRect(
                x: ((host.bounds.width - frame.width) / 2).rounded(),
                y: Self.topInset,
                width: frame.width,
                height: frame.height
            )
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.holdMs), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        isHidden = true
    }

    /// Sizes the HUD to its chips; the caller centers it at `topInset`.
    func sizeToContents() {
        let inset = Self.border * 2
        let height = (items.map(\.size.height).max() ?? 0) + Self.padY * 2 + inset
        let gaps = Self.itemGap * CGFloat(max(0, items.count - 1))
        let width = items.reduce(0) { $0 + $1.size.width } + gaps + Self.padX * 2 + inset
        frame = NSRect(x: frame.minX, y: frame.minY, width: width.rounded(), height: height.rounded())
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x = Self.border + Self.padX
        for item in items {
            item.frame = NSRect(
                x: x, y: ((bounds.height - item.size.height) / 2).rounded(),
                width: item.size.width, height: item.size.height
            )
            x += item.size.width + Self.itemGap
        }
    }
}

/// One chip of the cycle HUD. The active chip has a fill and a border, which
/// makes it a pixel larger on every side than the others.
@MainActor
final class CycleHUDItem: NSView {
    private static let padX: CGFloat = 7
    private static let padY: CGFloat = 2

    private let label: NSTextField
    let size: NSSize

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(text: String, active: Bool) {
        label = NSTextField(labelWithString: text)
        label.font = Theme.mono(10.5)
        label.textColor = active ? Theme.text : Theme.faint
        let border: CGFloat = active ? 1 : 0
        let text = label.fittedSize
        size = NSSize(
            width: (text.width + (Self.padX + border) * 2).rounded(),
            height: (text.height + (Self.padY + border) * 2).rounded()
        )
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 5
        if active {
            layer?.backgroundColor = Theme.bg3.cgColor
            layer?.borderColor = Theme.line.cgColor
            layer?.borderWidth = border
        }
        label.frame = NSRect(
            x: ((size.width - text.width) / 2).rounded(), y: ((size.height - text.height) / 2).rounded(),
            width: text.width, height: text.height
        )
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
