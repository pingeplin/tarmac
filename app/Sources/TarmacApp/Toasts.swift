import AppKit
import QuartzCore

/// Clickable toast kbd chip per the M0 crib chip spec (mono 500 10px muted,
/// bg2, 1px line border with a 2px bottom edge, radius 4, padding 1px 5px;
/// hover bg3 + text color). Lives here, not in PeekPanel: the peek's chip is
/// display-only.
@MainActor
final class ToastChipView: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField
    private let size: NSSize
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        label.font = Theme.mono(10, weight: .medium)
        label.textColor = Theme.muted
        let textSize = label.intrinsicContentSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 3)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4

        let bottomEdge = NSView(frame: NSRect(x: 1, y: 0, width: size.width - 2, height: 1))
        bottomEdge.wantsLayer = true
        bottomEdge.layer?.backgroundColor = Theme.line.cgColor
        bottomEdge.autoresizingMask = [.width]
        addSubview(bottomEdge)

        label.frame = NSRect(x: 5, y: 2, width: textSize.width, height: textSize.height)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { size }

    // Labels swallow mouseDown; capture clicks on children too.
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

@MainActor
final class ToastView: NSView {
    private let measuredSize: NSSize

    init(icon iconGlyph: String, title: String, body: String?, chips: [ToastChipView]) {
        let icon = NSTextField(labelWithString: iconGlyph)
        icon.font = Theme.mono(13)
        icon.textColor = Theme.agent

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Theme.mono(11)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let bodyLabel: NSTextField? = body.map {
            let label = NSTextField(labelWithString: $0)
            label.font = Theme.mono(10)
            label.textColor = Theme.faint
            return label
        }

        let maxContentWidth: CGFloat = 280
        let iconSize = icon.intrinsicContentSize
        let titleSize = NSSize(
            width: min(titleLabel.intrinsicContentSize.width, maxContentWidth),
            height: titleLabel.intrinsicContentSize.height
        )
        let bodySize = bodyLabel.map(\.intrinsicContentSize) ?? .zero
        // Chips: gap 5px within the group, 6px left margin (theme.css .tm-toast .keys).
        let chipSizes = chips.map(\.intrinsicContentSize)
        let chipsWidth = chipSizes.isEmpty
            ? 0
            : chipSizes.map(\.width).reduce(0, +) + CGFloat(chipSizes.count - 1) * 5 + 6
        let chipsHeight = chipSizes.map(\.height).max() ?? 0
        let contentWidth = max(iconSize.width + 7 + titleSize.width, iconSize.width + 7 + min(bodySize.width, maxContentWidth)) + chipsWidth
        let contentHeight = max(
            max(iconSize.height, titleSize.height) + (bodyLabel == nil ? 0 : 2 + bodySize.height),
            chipsHeight
        )
        measuredSize = NSSize(width: contentWidth + 24, height: contentHeight + 18)

        super.init(frame: NSRect(origin: .zero, size: measuredSize))
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor
        layer?.borderColor = Theme.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 9

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 14
        self.shadow = shadow

        // Flipped: lay out from the top.
        icon.frame = NSRect(x: 12, y: 9, width: iconSize.width, height: iconSize.height)
        titleLabel.frame = NSRect(x: 12 + iconSize.width + 7, y: 9, width: titleSize.width, height: titleSize.height)
        addSubview(icon)
        addSubview(titleLabel)
        if let bodyLabel {
            bodyLabel.frame = NSRect(
                x: 12 + iconSize.width + 7,
                y: 9 + max(iconSize.height, titleSize.height) + 2,
                width: min(bodySize.width, maxContentWidth),
                height: bodySize.height
            )
            addSubview(bodyLabel)
        }
        var chipX = measuredSize.width - 12 - chipsWidth + 6
        for (chip, size) in zip(chips, chipSizes) {
            chip.frame = NSRect(
                x: chipX,
                y: ((measuredSize.height - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            addSubview(chip)
            chipX += size.width + 5
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { measuredSize }
}

/// Full-bounds, click-through overlay anchored bottom-right (right 14, bottom 38),
/// max 3 toasts, 8px gap, newest at the bottom, auto-dismiss 7 s.
@MainActor
final class ToastStackView: NSView {
    private struct Entry {
        let view: ToastView
        let dismissWork: DispatchWorkItem
    }

    private var entries: [Entry] = [] // newest first

    var hasToasts: Bool { !entries.isEmpty }

    override var isFlipped: Bool { true }

    // Click-through everywhere except the kbd chips (focus rule: nothing here
    // may take clicks the terminal needs).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is ToastChipView ? hit : nil
    }

    /// Chips per docs/m1/crib-dock-index.md §1.2: each runs its action (nil =
    /// dismiss only), then dismisses its own toast — never the whole stack.
    func show(icon: String = "¶", title: String, body: String?, chips: [(label: String, action: (() -> Void)?)] = []) {
        if entries.count >= 3, let oldest = entries.last {
            removeEntry(oldest.view, animated: false)
        }
        let chipViews = chips.map { ToastChipView($0.label) }
        let toast = ToastView(icon: icon, title: title, body: body, chips: chipViews)
        for (view, chip) in zip(chipViews, chips) {
            view.onClick = { [weak self, weak toast] in
                chip.action?()
                guard let self, let toast else { return }
                self.removeEntry(toast, animated: true)
            }
        }
        addSubview(toast)

        let work = DispatchWorkItem { [weak self, weak toast] in
            MainActor.assumeIsolated {
                guard let self, let toast else { return }
                self.removeEntry(toast, animated: true)
            }
        }
        entries.insert(Entry(view: toast, dismissWork: work), at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)

        relayoutToasts(entering: toast)
    }

    func clearAll() {
        for entry in entries {
            entry.dismissWork.cancel()
            entry.view.removeFromSuperview()
        }
        entries.removeAll()
    }

    private func removeEntry(_ toast: ToastView, animated: Bool) {
        guard let index = entries.firstIndex(where: { $0.view === toast }) else { return }
        entries[index].dismissWork.cancel()
        entries.remove(at: index)
        if animated && !Theme.reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                toast.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    toast.removeFromSuperview()
                }
            })
        } else {
            toast.removeFromSuperview()
        }
        relayoutToasts(entering: nil)
    }

    private func relayoutToasts(entering newToast: ToastView?) {
        var bottom = bounds.height - 38 // flipped coords: y of the newest toast's bottom edge
        var targets: [(ToastView, NSRect)] = []
        for entry in entries {
            let size = entry.view.intrinsicContentSize
            let frame = NSRect(
                x: bounds.width - 14 - size.width,
                y: bottom - size.height,
                width: size.width,
                height: size.height
            )
            targets.append((entry.view, frame))
            bottom -= size.height + 8
        }

        if Theme.reduceMotion {
            for (view, frame) in targets { view.frame = frame }
            return
        }
        if let newToast, let target = targets.first(where: { $0.0 === newToast })?.1 {
            // Enter: +8px below, faded out, 180ms rise per the crib.
            newToast.frame = target.offsetBy(dx: 0, dy: 8)
            newToast.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            for (view, frame) in targets {
                view.animator().frame = frame
                if view === newToast { view.animator().alphaValue = 1 }
            }
        }
    }

    override func layout() {
        super.layout()
        relayoutToastsImmediately()
    }

    private func relayoutToastsImmediately() {
        var bottom = bounds.height - 38
        for entry in entries {
            let size = entry.view.intrinsicContentSize
            entry.view.frame = NSRect(
                x: bounds.width - 14 - size.width,
                y: bottom - size.height,
                width: size.width,
                height: size.height
            )
            bottom -= size.height + 8
        }
    }
}
