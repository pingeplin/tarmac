import AppKit

/// The titlebar session chip (M3 P4, design ref parts.jsx `.tm-session` /
/// board-v4.jsx TitleBar): a small pill just right of the traffic lights showing
/// `▞ <board>` — the `▞` glyph in agent cyan, the active board's display name in
/// muted mono. Hosted in an `NSTitlebarAccessoryViewController` (leading), so the
/// native window chrome carries the board identity. Dimmed (with the traffic
/// lights) while the ⌘K switcher is open, matching B5's `dim` titlebar.
@MainActor
final class TitleBarChip: NSView {
    private let pill = NSView()
    private let glyph = NSTextField(labelWithString: "▞")
    private let label = NSTextField(labelWithString: "")

    /// Inset from the traffic lights before the pill starts.
    private static let leading: CGFloat = 8
    private static let padX: CGFloat = 8
    private static let gap: CGFloat = 5
    private static let pillH: CGFloat = 20
    private static let height: CGFloat = 28

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        wantsLayer = true

        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.bg2.cgColor
        pill.layer?.borderColor = Theme.lineSoft.cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = 5
        addSubview(pill)

        glyph.font = Theme.mono(11, weight: .semibold)
        glyph.textColor = Theme.agent
        glyph.drawsBackground = false
        glyph.isBezeled = false
        pill.addSubview(glyph)

        label.font = Theme.mono(11, weight: .medium)
        label.textColor = Theme.muted
        label.drawsBackground = false
        label.isBezeled = false
        pill.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the active board's display name and resizes to fit (so the leading
    /// titlebar accessory claims exactly the chip's width).
    func setName(_ name: String) {
        label.stringValue = name
        let size = intrinsicContentSize
        setFrameSize(NSSize(width: size.width, height: Self.height))
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        glyph.sizeToFit()
        label.sizeToFit()
        let w = Self.leading + Self.padX + glyph.frame.width + Self.gap + label.frame.width + Self.padX
        return NSSize(width: w, height: Self.height)
    }

    override func layout() {
        super.layout()
        glyph.sizeToFit()
        label.sizeToFit()
        let gW = glyph.frame.width, gH = glyph.frame.height
        let lW = label.frame.width, lH = label.frame.height
        let pillW = Self.padX + gW + Self.gap + lW + Self.padX
        let pillY = ((bounds.height - Self.pillH) / 2).rounded()
        pill.frame = NSRect(x: Self.leading, y: pillY, width: pillW, height: Self.pillH)
        glyph.frame = NSRect(x: Self.padX, y: ((Self.pillH - gH) / 2).rounded(), width: gW, height: gH)
        label.frame = NSRect(x: Self.padX + gW + Self.gap, y: ((Self.pillH - lH) / 2).rounded(), width: lW, height: lH)
    }
}
