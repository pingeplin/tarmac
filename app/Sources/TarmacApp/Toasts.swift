import AppKit
import QuartzCore
import TarmacKit

/// A toast's kbd chip: the one part of a toast that takes a click.
@MainActor
final class ToastChipView: NSView {
    var onClick: (() -> Void)?

    private static let padX: CGFloat = 5
    private static let padY: CGFloat = 2
    private static let border: CGFloat = 1
    private static let bottomBorder: CGFloat = 2

    private let label: ChromeLabel
    let size: NSSize
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(_ text: String) {
        label = ChromeLabel(text, size: 10, color: Theme.muted, weight: .medium)
        let textSize = label.textSize
        size = NSSize(
            width: (textSize.width + 2 * (Self.padX + Self.border)).rounded(.up),
            height: textSize.height + 2 * Self.padY + Self.border + Self.bottomBorder
        )
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = Self.border
        layer?.cornerRadius = 4

        let bottomEdge = NSView(frame: NSRect(
            x: Self.border, y: size.height - Self.bottomBorder,
            width: size.width - 2 * Self.border, height: Self.bottomBorder - Self.border
        ))
        bottomEdge.wantsLayer = true
        bottomEdge.layer?.backgroundColor = Theme.line.cgColor
        addSubview(bottomEdge)

        label.place(at: CGPoint(x: Self.border + Self.padX, y: Self.border + Self.padY))
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // The label would otherwise swallow the press.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.bg3.cgColor
        label.textColor = Theme.text
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = Theme.bg2.cgColor
        label.textColor = Theme.muted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// One toast: a glyph, a title over an optional body, and its chips. Laid out
/// as `.tm-toast` is, a border box of at most 320 px.
@MainActor
final class ToastView: NSView {
    private static let maxWidth: CGFloat = 320
    private static let maxTextWidth: CGFloat = 280
    private static let insetX: CGFloat = 1 + 12
    private static let insetY: CGFloat = 1 + 9
    private static let gap: CGFloat = 7
    private static let iconLineHeight: CGFloat = 13 * 1.2
    private static let bodyTop: CGFloat = 2
    private static let chipGap: CGFloat = 5
    private static let chipsLeft: CGFloat = 6

    let size: NSSize

    init(_ toast: ToastQueue.Toast, onChip: @escaping () -> Void) {
        let icon = ChromeLabel(toast.icon, size: 13, color: Theme.agent)
        let title = ChromeLabel(toast.title, size: 11, color: Theme.text)
        let body = toast.body.map { ChromeLabel($0, size: 10, color: Theme.faint) }
        let chips = toast.chips.map { ToastChipView($0.label) }

        let iconWidth = icon.textSize.width
        let chipsWidth = chips.isEmpty
            ? 0
            : Self.gap + Self.chipsLeft + chips.map(\.size.width).reduce(0, +)
                + CGFloat(chips.count - 1) * Self.chipGap
        let textRoom = min(
            Self.maxTextWidth, Self.maxWidth - 2 * Self.insetX - iconWidth - Self.gap - chipsWidth
        )
        let titleWidth = min(title.textSize.width, textRoom)
        let bodyWidth = min(body?.textSize.width ?? 0, textRoom)
        let textWidth = max(titleWidth, bodyWidth)
        let textHeight = title.lineHeight + (body.map { Self.bodyTop + $0.lineHeight } ?? 0)
        let contentHeight = max(Self.iconLineHeight, textHeight, chips.map(\.size.height).max() ?? 0)
        size = NSSize(
            width: (2 * Self.insetX + iconWidth + Self.gap + textWidth + chipsWidth).rounded(.up),
            height: (2 * Self.insetY + contentHeight).rounded(.up)
        )

        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 9
        shadow = OverlayPalette.toastShadow

        // The glyph's line box is shorter than its font's own line, so the
        // glyph sits above the box's top by half the difference.
        let iconY = Self.insetY + (Self.iconLineHeight - icon.lineHeight) / 2
        icon.place(at: CGPoint(x: Self.insetX, y: iconY.rounded()))
        addSubview(icon)

        let textX = Self.insetX + iconWidth + Self.gap
        title.place(at: CGPoint(x: textX, y: Self.insetY), width: titleWidth)
        addSubview(title)
        if let body {
            let bodyY = Self.insetY + title.lineHeight + Self.bodyTop
            body.place(at: CGPoint(x: textX, y: bodyY.rounded()), width: bodyWidth)
            addSubview(body)
        }

        var chipX = textX + textWidth + Self.gap + Self.chipsLeft
        for chip in chips {
            chip.onClick = onChip
            chip.frame.origin = CGPoint(
                x: chipX.rounded(), y: (Self.insetY + (contentHeight - chip.size.height) / 2).rounded()
            )
            addSubview(chip)
            chipX += chip.size.width + Self.chipGap
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
}

/// The toast column over the board's bottom-right corner. `ToastQueue` decides
/// which toasts there are and `ToastStackLayout` where they go; this draws
/// them. Click-through except for the chips.
@MainActor
final class ToastStackView: NSView {
    private static let pruneInterval: TimeInterval = 0.25
    private static let entryRise: CGFloat = 8
    private static let entryDuration: TimeInterval = 0.18

    private var queue = ToastQueue()
    private var views: [String: ToastView] = [:]
    private var minted = 0
    private var pruneTimer: Timer?

    var hasToasts: Bool { !queue.toasts.isEmpty }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is ToastChipView ? hit : nil
    }

    /// Clicking any chip dismisses its own toast, never the whole stack.
    func show(icon: String = "¶", title: String, body: String?, chips: [String] = []) {
        minted += 1
        let id = "toast-\(minted)"
        queue.add(
            id: id, icon: icon, title: title, body: body, chips: chips.map(ToastQueue.Chip.init),
            nowMs: Self.nowMs
        )
        render()
        if let view = views[id] { animateIn(view) }
    }

    func clearAll() {
        queue.clearAll()
        render()
    }

    private static var nowMs: Int {
        Int(ProcessInfo.processInfo.systemUptime * 1000)
    }

    private func dismiss(_ id: String) {
        queue.dismiss(id: id)
        render()
    }

    private func render() {
        let showing = Set(queue.toasts.map(\.id))
        for (id, view) in views where !showing.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for toast in queue.toasts where views[toast.id] == nil {
            let id = toast.id
            let view = ToastView(toast) { [weak self] in self?.dismiss(id) }
            views[id] = view
            addSubview(view)
        }
        place()
        schedulePrune()
    }

    private func place() {
        let ordered = queue.toasts.compactMap { views[$0.id] }
        let frames = ToastStackLayout.frames(sizes: ordered.map(\.size), in: bounds)
        for (view, frame) in zip(ordered, frames) { view.frame = frame }
    }

    /// Only the toast that just arrived moves; the ones it pushed up jump.
    private func animateIn(_ view: ToastView) {
        guard !Theme.reduceMotion else { return }
        let target = view.frame
        view.frame = target.offsetBy(dx: 0, dy: Self.entryRise)
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.entryDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            view.animator().frame = target
            view.animator().alphaValue = 1
        }
    }

    private func schedulePrune() {
        guard hasToasts else {
            pruneTimer?.invalidate()
            pruneTimer = nil
            return
        }
        guard pruneTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pruneInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        // Common modes, so a toast still expires while a menu or a drag tracks.
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    private func prune() {
        let before = queue
        queue.pruneExpired(nowMs: Self.nowMs)
        if queue != before { render() }
    }

    override func layout() {
        super.layout()
        place()
    }
}
