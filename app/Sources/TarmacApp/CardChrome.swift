import AppKit
import QuartzCore
import TarmacKit

// Shared card/tile chrome (was TileView.swift). The v4 `CardView` (board cards)
// reuses these components; the desk-grid `TileView`/`DashedBorderView` were
// removed with `DeskGridView` in Phase 2c. `UnpinButton` is retained as the
// `TileHeaderView.init(unpinButton:)` type (CardView passes nil; Phase 3 may
// reintroduce a per-card affordance).

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

/// 30px card header (crib §4): bg2, line-soft bottom hairline, padding 0 11px,
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

        var x: CGFloat = 11
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

        // Right edge per crib §4 (README wins): [meta][gap 7][✕].
        var rightX = bounds.width - 11
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

/// Terminal card body: term-bg with the crib §4 card body padding (14px h / 10px v).
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
            x: 14,
            y: 10,
            width: max(0, bounds.width - 28),
            height: max(0, bounds.height - 20)
        )
    }
}

