import AppKit
import QuartzCore

/// Terminal-only cycle HUD (crib §6 `.tm-cyclehud`, migration-plan Phase 5):
/// a top-center HUD that appears briefly while ⌥tab cycles the focused terminal
/// among terminal cards. bg2, 1px line border, radius 10, shadow
/// `0 8px 22px rgba(0,0,0,0.5)`, padding 4, items gap 4. Each item: padding
/// `5px 10px`, radius 7, 10.5px mono; the active item gets bg3 + `text` color +
/// an inset 1px line border, inactive items are `muted`.
///
/// With one terminal this shows a single item (the term name) and ⌥tab is a
/// no-op cycle — kept minimal but real so Phase 5b can populate it with the full
/// terminal-card set without rewiring.
@MainActor
final class CycleHUD: NSView {
    /// Top offset from the board top edge (crib §6: `top 12`).
    static let topInset: CGFloat = 12

    private static let padding: CGFloat = 4
    private static let itemGap: CGFloat = 4
    private static let itemPadX: CGFloat = 10
    private static let itemPadY: CGFloat = 5

    private var items: [CycleHUDItem] = []
    private var hideWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    // Click-through: the HUD is a transient readout, never a target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 10

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowBlurRadius = 22
        self.shadow = shadow

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the HUD with `labels` (terminal names), highlighting `activeIndex`,
    /// and auto-hides after a short hold (crib §6: "show the HUD briefly while
    /// held"). Re-pressing ⌥tab before it hides resets the timer and advances the
    /// highlight.
    func show(labels: [String], activeIndex: Int) {
        for item in items { item.removeFromSuperview() }
        items = labels.enumerated().map { idx, text in
            let item = CycleHUDItem(text: text)
            item.setActive(idx == activeIndex)
            addSubview(item)
            return item
        }
        isHidden = false
        sizeToContents()
        // Center horizontally at the top inset immediately so the HUD never
        // flashes at the corner before the host's next layout pass.
        if let host = superview {
            frame = NSRect(
                x: ((host.bounds.width - frame.width) / 2).rounded(),
                y: Self.topInset,
                width: frame.width,
                height: frame.height
            )
        }
        // Re-arm the auto-hide.
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        isHidden = true
    }

    /// Sizes the HUD to its items at the canonical paddings; the caller centers
    /// it horizontally at `topInset`.
    func sizeToContents() {
        let h = Self.itemPadY * 2 + (items.map { $0.fittedSize.height }.max() ?? 0) + Self.padding * 2
        var w = Self.padding * 2
        for (idx, item) in items.enumerated() {
            w += item.fittedSize.width + Self.itemPadX * 2
            if idx < items.count - 1 { w += Self.itemGap }
        }
        frame = NSRect(x: frame.minX, y: frame.minY, width: w.rounded(), height: h.rounded())
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height - Self.padding * 2
        var x = Self.padding
        for (idx, item) in items.enumerated() {
            let iw = item.fittedSize.width + Self.itemPadX * 2
            item.frame = NSRect(x: x, y: Self.padding, width: iw, height: h)
            x += iw
            if idx < items.count - 1 { x += Self.itemGap }
        }
    }
}

/// One cycle-HUD item (crib §6 `.tm-cyclehud .c`): 10.5px mono. Active = bg3 +
/// `text` color + inset 1px line border (radius 7); inactive = transparent +
/// `muted`. Click-through (the HUD is a readout).
@MainActor
final class CycleHUDItem: NSView {
    private let label: NSTextField

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        label.font = Theme.mono(10.5)
        label.textColor = Theme.muted
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var fittedSize: NSSize { label.fittedSize }

    func setActive(_ on: Bool) {
        if on {
            layer?.backgroundColor = Theme.bg3.cgColor
            layer?.borderColor = Theme.line.cgColor
            layer?.borderWidth = 1 // inset 1px line border
            label.textColor = Theme.text
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            label.textColor = Theme.muted
        }
    }

    override func layout() {
        super.layout()
        let size = label.fittedSize
        label.frame = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
