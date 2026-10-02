import AppKit
import QuartzCore
import TarmacKit

/// One toast: a glyph and a title over an optional body. Laid out as
/// `.tm-toast` is, a border box of at most 320 px.
@MainActor
final class ToastView: NSView {
    private static let maxWidth: CGFloat = 320
    private static let maxTextWidth: CGFloat = 280
    private static let insetX: CGFloat = 1 + 12
    private static let insetY: CGFloat = 1 + 9
    private static let gap: CGFloat = 7
    private static let iconLineHeight: CGFloat = 13 * 1.2
    private static let bodyTop: CGFloat = 2

    let size: NSSize

    init(_ toast: ToastQueue.Toast) {
        let icon = ChromeLabel(toast.icon, size: 13, color: Theme.agent)
        let title = ChromeLabel(toast.title, size: 11, color: Theme.text)
        let body = toast.body.map { ChromeLabel($0, size: 10, color: Theme.faint) }

        let iconWidth = icon.textSize.width
        let textRoom = min(Self.maxTextWidth, Self.maxWidth - 2 * Self.insetX - iconWidth - Self.gap)
        let titleWidth = min(title.textSize.width, textRoom)
        let bodyWidth = min(body?.textSize.width ?? 0, textRoom)
        let textWidth = max(titleWidth, bodyWidth)
        let textHeight = title.lineHeight + (body.map { Self.bodyTop + $0.lineHeight } ?? 0)
        let contentHeight = max(Self.iconLineHeight, textHeight)
        size = NSSize(
            width: (2 * Self.insetX + iconWidth + Self.gap + textWidth).rounded(.up),
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
}

/// The toast column over the board's bottom-right corner. `ToastQueue` decides
/// which toasts there are and `ToastStackLayout` where they go; this draws
/// them. Click-through.
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(icon: String = "¶", title: String, body: String?) {
        minted += 1
        let id = "toast-\(minted)"
        queue.add(id: id, icon: icon, title: title, body: body, nowMs: Self.nowMs)
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

    private func render() {
        let showing = Set(queue.toasts.map(\.id))
        for (id, view) in views where !showing.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for toast in queue.toasts where views[toast.id] == nil {
            let view = ToastView(toast)
            views[toast.id] = view
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
