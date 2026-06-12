import AppKit
import QuartzCore
import TarmacKit

/// `✎ Ns` honest meta (crib-desk-tiles §3): visible while the 30s recency
/// window is open, ticking at 1Hz (display granularity is 1s). The tick is a
/// state display, not motion — it stays under Reduce Motion (crib-state §3.2).
@MainActor
final class RecentMetaLabel: NSTextField {
    var onUpdate: (() -> Void)?

    private var lastChangedMs: UInt64?
    private var tickWork: DispatchWorkItem?

    init(font: NSFont, color: NSColor) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        self.font = font
        textColor = color
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setChanged(_ ms: UInt64?) {
        lastChangedMs = ms
        refresh()
    }

    private func refresh() {
        tickWork?.cancel()
        tickWork = nil
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        guard let changed = lastChangedMs, DocStore.isRecent(lastChangedMs: changed, nowMs: nowMs) else {
            if !isHidden {
                isHidden = true
                onUpdate?()
            }
            return
        }
        let elapsed = nowMs > changed ? nowMs - changed : 0
        let n = max(1, Int((Double(elapsed) / 1000).rounded()))
        stringValue = "✎ \(n)s"
        sizeToFit()
        isHidden = false
        onUpdate?()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        tickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Unpin ✕ per crib §2: label `⌘⏎ ✕`, mono 10px faint, padding 2px 5px,
/// radius 4; hover bg3 + text. Owns its mouse-down so a press here never
/// reaches the header (and never starts a drag).
@MainActor
final class UnpinButton: NSView {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "⌘⏎ ✕")
    private let size: NSSize
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init() {
        label.font = Theme.mono(10)
        label.textColor = Theme.faint
        let textSize = label.intrinsicContentSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 4)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 4
        toolTip = "unpin (back to dock)"
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
        layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = Theme.faint
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

/// 28px tile header (crib §2): bg2, line-soft bottom hairline, padding 0 10px,
/// gap 7px, mono 400 10.5px muted. The header is the drag handle; the unpin ✕
/// is the one child that keeps its own mouse handling.
@MainActor
final class TileHeaderView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    let meta = RecentMetaLabel(font: Theme.mono(9.5), color: Theme.agent)
    let unpinButton: UnpinButton?
    private let hairline = NSView()
    private let kindGlyph: NSTextField
    private let repoDot: NSView?
    private let pathLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(kindGlyph glyph: String, showsRepoDot: Bool, unpinButton: UnpinButton?) {
        kindGlyph = NSTextField(labelWithString: glyph)
        repoDot = showsRepoDot ? NSView() : nil
        self.unpinButton = unpinButton
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        addSubview(hairline)

        kindGlyph.font = Theme.mono(10.5)
        kindGlyph.textColor = Theme.faint
        addSubview(kindGlyph)

        if let repoDot {
            repoDot.wantsLayer = true
            repoDot.layer?.cornerRadius = 3.5
            addSubview(repoDot)
        }

        pathLabel.font = Theme.mono(10.5)
        pathLabel.textColor = Theme.muted
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)

        meta.onUpdate = { [weak self] in self?.needsLayout = true }
        addSubview(meta)

        if let unpinButton { addSubview(unpinButton) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(doc: RestoreDoc) {
        pathLabel.stringValue = doc.displayPath
        repoDot?.layer?.backgroundColor =
            Theme.repoColor(index: doc.repoColor, fallbackName: doc.displayRepoName).cgColor
        meta.setChanged(doc.lastChangedMs)
        needsLayout = true
    }

    func setLabel(_ text: String) {
        pathLabel.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        hairline.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)

        var x: CGFloat = 10
        let glyphSize = kindGlyph.fittedSize
        kindGlyph.frame = NSRect(
            x: x,
            y: ((h - glyphSize.height) / 2).rounded(),
            width: glyphSize.width,
            height: glyphSize.height
        )
        x = kindGlyph.frame.maxX + 7
        if let repoDot {
            repoDot.frame = NSRect(x: x, y: ((h - 7) / 2).rounded(), width: 7, height: 7)
            x += 7 + 7
        }

        // Right edge per crib §2 (README wins): [meta][gap 7][✕].
        var rightX = bounds.width - 10
        if let unpinButton {
            let size = unpinButton.intrinsicContentSize
            unpinButton.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = unpinButton.frame.minX - 7
        }
        if !meta.isHidden {
            let size = meta.frame.size
            meta.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = meta.frame.minX - 7
        }
        let labelHeight = pathLabel.intrinsicContentSize.height
        pathLabel.frame = NSRect(
            x: x,
            y: ((h - labelHeight) / 2).rounded(),
            width: max(0, min(pathLabel.fittedSize.width, rightX - x)),
            height: labelHeight
        )
    }

    // The whole header is the drag handle except the ✕ (crib §5 initiation).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let unpinButton, hit === unpinButton { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Terminal tile body: term-bg with the M0 12px/16px body padding.
@MainActor
final class TerminalBodyView: NSView {
    private(set) weak var terminal: NSView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.termBg.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(_ terminal: NSView) {
        self.terminal = terminal
        addSubview(terminal)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        terminal?.frame = NSRect(
            x: 16,
            y: 12,
            width: max(0, bounds.width - 32),
            height: max(0, bounds.height - 24)
        )
    }
}

/// Drop-target border (crib §5): 1.5px dashed agent replacing the solid line.
/// Stroke is centered 0.75px inside; dash segments ≈3× line width (CSS
/// `dashed` has no authored segment length — this matches UA rendering).
@MainActor
final class DashedBorderView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 8.25,
            yRadius: 8.25
        )
        path.lineWidth = 1.5
        var pattern: [CGFloat] = [4.5, 4.5]
        path.setLineDash(&pattern, count: 2, phase: 0)
        Theme.agent.setStroke()
        path.stroke()
    }
}

/// Tile chrome per crib §2: bg1, 1px line border, 9px radius, 28px header,
/// body below. The outer layer carries border + drag shadow; content lives in
/// an inner rounded clip so the lift shadow is not masked away.
@MainActor
final class TileView: NSView {
    let key: TileKey
    let header: TileHeaderView
    private(set) var docView: DocWebView?
    private(set) var termBody: TerminalBodyView?

    private let clip = FlippedColumnView()
    private let body: NSView
    private let dropBorder = DashedBorderView()
    private var lifted = false
    private var dropTarget = false
    private var liftCleanup: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(key: TileKey) {
        self.key = key
        switch key {
        case .term:
            header = TileHeaderView(kindGlyph: "›_", showsRepoDot: false, unpinButton: nil)
            let term = TerminalBodyView()
            termBody = term
            body = term
        case .doc:
            header = TileHeaderView(kindGlyph: "¶", showsRepoDot: true, unpinButton: UnpinButton())
            let doc = DocWebView()
            docView = doc
            body = doc
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor

        clip.wantsLayer = true
        clip.layer?.backgroundColor = Theme.bg1.cgColor
        clip.layer?.cornerRadius = 9
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(header)
        clip.addSubview(body)

        dropBorder.isHidden = true
        addSubview(dropBorder)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        clip.frame = bounds
        dropBorder.frame = bounds
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        body.frame = NSRect(x: 0, y: 28, width: bounds.width, height: max(0, bounds.height - 28))
    }

    // MARK: - Drag styling (crib §5)

    /// Lift pops on instantly (`transition: none` while dragging); release
    /// fades shadow/border back over the base 150ms ease — kept under Reduce
    /// Motion per crib §5 (the prototype gates peek/toast/pulse only).
    func setLifted(_ on: Bool) {
        guard on != lifted, let layer else { return }
        lifted = on
        liftCleanup?.cancel()
        liftCleanup = nil
        if on {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.borderColor = Theme.liftBorder.cgColor
            layer.zPosition = 1
            CATransaction.commit()
            // 0 18px 44px black @60% (blur halved per the M0 shadow convention).
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = NSSize(width: 0, height: -18)
            shadow.shadowBlurRadius = 22
            self.shadow = shadow
        } else {
            let ease = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            let border = CABasicAnimation(keyPath: "borderColor")
            border.fromValue = Theme.liftBorder.cgColor
            border.toValue = Theme.line.cgColor
            border.duration = 0.15
            border.timingFunction = ease
            layer.borderColor = Theme.line.cgColor
            layer.add(border, forKey: "liftBorderOff")
            let fade = CABasicAnimation(keyPath: "shadowOpacity")
            fade.fromValue = layer.shadowOpacity
            fade.toValue = 0
            fade.duration = 0.15
            fade.timingFunction = ease
            layer.shadowOpacity = 0
            layer.add(fade, forKey: "liftShadowOff")
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.lifted else { return }
                    self.shadow = nil
                    self.layer?.zPosition = 0
                }
            }
            liftCleanup = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    /// Pointer-follow is 1:1 with no smoothing; rotation −0.5° about the center.
    func setDragTransform(dx: CGFloat, dy: CGFloat) {
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CGAffineTransform(translationX: dx + center.x, y: dy + center.y)
        transform = transform.rotated(by: -0.5 * .pi / 180)
        transform = transform.translatedBy(x: -center.x, y: -center.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// Snap back/into the slot is instant — transform is not in the transition list.
    func clearDragTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    /// CSS only transitions border-color: the dashed style flips instantly and
    /// the cyan fades in/out over 150ms ease (kept under Reduce Motion, crib §5).
    func setDropTarget(_ on: Bool) {
        guard on != dropTarget, let layer else { return }
        dropTarget = on
        if on {
            layer.borderWidth = 0
            dropBorder.alphaValue = 0
            dropBorder.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
                dropBorder.animator().alphaValue = 1
            }
        } else {
            dropBorder.isHidden = true
            dropBorder.alphaValue = 1
            layer.borderWidth = 1
            let fade = CABasicAnimation(keyPath: "borderColor")
            fade.fromValue = Theme.agent.cgColor
            fade.toValue = Theme.line.cgColor
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            layer.add(fade, forKey: "dropBorderOff")
        }
    }
}
