import AppKit
import QuartzCore

@MainActor
final class ToastView: NSView {
    private let measuredSize: NSSize

    init(title: String, body: String?) {
        let icon = NSTextField(labelWithString: "¶")
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
        let contentWidth = max(iconSize.width + 7 + titleSize.width, iconSize.width + 7 + min(bodySize.width, maxContentWidth))
        let contentHeight = max(iconSize.height, titleSize.height) + (bodyLabel == nil ? 0 : 2 + bodySize.height)
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, body: String?) {
        if entries.count >= 3, let oldest = entries.last {
            removeEntry(oldest.view, animated: false)
        }
        let toast = ToastView(title: title, body: body)
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
