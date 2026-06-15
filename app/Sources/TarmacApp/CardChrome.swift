import AppKit
import QuartzCore
import TarmacKit

/// A top-down (flipped) container view. Was defined in the now-removed
/// DockView.swift; relocated here as it backs `CardView.clip`, `BoardView`'s
/// card layer, the shelf, and the edge layer.
@MainActor
final class FlippedColumnView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// NSTextField's intrinsicContentSize under-reports its drawn width (cell
/// insets), which triggers spurious truncation at exact-fit frames; measure
/// via sizeToFit instead. (Was defined in the now-removed DockView.swift.)
@MainActor
extension NSTextField {
    var fittedSize: NSSize {
        let saved = frame
        sizeToFit()
        let size = frame.size
        frame = saved
        return size
    }
}

// Shared card/tile chrome (was TileView.swift). The v4 `CardView` (board cards)
// reuses these components; the desk-grid `TileView`/`DashedBorderView` were
// removed with `DeskGridView` in Phase 2c. `CloseButton` is the doc card's
// header ✕ (close-to-shelf) affordance; term cards pass nil.

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

/// Doc-card close ✕ (crib §2): label `✕`, mono 10px faint, padding 2px 5px,
/// radius 4; hover bg3 + text. Owns its mouse-down so a press here never
/// reaches the header (and never starts a drag).
@MainActor
final class CloseButton: NSView {
    var onClick: (() -> Void)?

    /// Resting (non-hover) background. `.clear` for the in-header ✕ — the header
    /// is its backdrop. The viewport-floating twin (see `BoardView.floatingClose`)
    /// sets a visible chip, since it sits over arbitrary doc content with no
    /// header behind it.
    var restingBackground: NSColor = .clear {
        didSet { layer?.backgroundColor = restingBackground.cgColor }
    }

    private let label = NSTextField(labelWithString: "✕")
    private let size: NSSize
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init() {
        label.font = Theme.mono(11)
        label.textColor = Theme.muted
        // `fittedSize`, not `intrinsicContentSize`: the latter under-reports a
        // label's drawn width (see the NSTextField note atop this file), so an
        // exact-fit `label.frame` clips the glyph's right edge — visible as the ✕
        // losing its right arm, magnified under zoom. The other header labels
        // already measure via `fittedSize`; this is the one that was missed.
        let textSize = label.fittedSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 4)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 4
        toolTip = "close (to shelf)"
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
        layer?.backgroundColor = restingBackground.cgColor
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

/// `← <termname>` owner chip (crib §4): an attached doc card's header shows its
/// owner term. Faint 9px mono, 1px line-soft border, radius 4, padding 1px 6px.
/// Display-only (click-through).
@MainActor
final class OwnerChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var size: NSSize = .zero

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = Theme.lineSoft.cgColor
        label.font = Theme.mono(9)
        label.textColor = Theme.faint
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setLabel(_ text: String) {
        label.stringValue = text
        let textSize = label.intrinsicContentSize
        // padding 1px 6px.
        size = NSSize(width: textSize.width + 12, height: textSize.height + 2)
        label.frame = NSRect(x: 6, y: 1, width: textSize.width, height: textSize.height)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { size }
}

/// 30px card header (crib §4): bg2, line-soft bottom hairline, padding 0 11px,
/// gap 7px, mono 400 10.5px muted. The header is the drag handle; the close ✕
/// is the one child that keeps its own mouse handling.
@MainActor
final class TileHeaderView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    let meta = RecentMetaLabel(font: Theme.mono(9.5), color: Theme.agent)
    let closeButton: CloseButton?
    private let hairline = NSView()
    private let kindGlyph: NSTextField
    private let repoDot: NSView?
    private let pathLabel = NSTextField(labelWithString: "")
    // Phase 3 header right-cluster extras: `✚ now` fresh badge (agent cyan) and
    // a `← <termname>` owner chip (faint, line-soft border) for an attached doc.
    private let freshMeta = NSTextField(labelWithString: "✚ now")
    private let ownerChip = OwnerChipView()
    // Phase 3.5 (M2 honest signals): an amber `●` bell dot in the right cluster,
    // shown when a BEL was seen, cleared on the next keystroke / focus.
    private let bellDot = NSTextField(labelWithString: "●")

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(kindGlyph glyph: String, showsRepoDot: Bool, closeButton: CloseButton?) {
        kindGlyph = NSTextField(labelWithString: glyph)
        repoDot = showsRepoDot ? NSView() : nil
        self.closeButton = closeButton
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

        freshMeta.font = Theme.mono(9.5)
        freshMeta.textColor = Theme.agent
        freshMeta.isHidden = true
        addSubview(freshMeta)

        ownerChip.isHidden = true
        addSubview(ownerChip)

        bellDot.font = Theme.mono(9)
        bellDot.textColor = Theme.amber
        bellDot.isEditable = false
        bellDot.isSelectable = false
        bellDot.isBezeled = false
        bellDot.drawsBackground = false
        bellDot.toolTip = "bell"
        bellDot.isHidden = true
        addSubview(bellDot)

        if let closeButton { addSubview(closeButton) }
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

    /// `✚ now` fresh badge (crib §5): a freshly-landed CLI doc card shows it in
    /// agent cyan until selected / marked read.
    func setFreshMeta(_ on: Bool) {
        guard on != !freshMeta.isHidden else { return }
        freshMeta.isHidden = !on
        if on { freshMeta.sizeToFit() }
        needsLayout = true
    }

    /// `← <termname>` owner chip (crib §4): an attached doc card shows its
    /// owner term's current label; a detached (loose) card passes nil.
    func setOwnerChip(_ termName: String?) {
        if let termName {
            ownerChip.setLabel("← \(termName)")
            ownerChip.isHidden = false
        } else {
            ownerChip.isHidden = true
        }
        needsLayout = true
    }

    /// Phase 3.5 (M2 honest signals): an amber bell signal — a `●` dot in the
    /// right cluster plus an amber accent on the kind glyph — shown when a BEL
    /// was seen, cleared on the next keystroke to / focus on the terminal. This
    /// is a state display (no animation; stays under Reduce Motion).
    func setBell(_ on: Bool) {
        guard on != !bellDot.isHidden else { return }
        bellDot.isHidden = !on
        kindGlyph.textColor = on ? Theme.amber : Theme.faint
        needsLayout = true
    }

    /// Prime-header styling (crib §4 `.tm-bcard.prime .bhd`): bg `#3a4046`, label
    /// text `text`. The focused terminal card uses it; off restores the resting
    /// bg2 + muted label. Display-only.
    func setPrime(_ on: Bool) {
        layer?.backgroundColor = (on ? Theme.primeHeaderBg : Theme.bg2).cgColor
        pathLabel.textColor = on ? Theme.text : Theme.muted
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

        // Right edge per crib §4/§5: right-to-left cluster
        // [ownerChip][freshMeta][meta][✕][bell], gap 7 (mr cluster gap 8 ≈ 7).
        // Inset 13 (vs the leading 11) clears the radius-10 corner and the
        // corner-seated resize handle, so the ✕ never reads as clipped.
        var rightX = bounds.width - 13
        if !bellDot.isHidden {
            let size = bellDot.fittedSize
            bellDot.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = bellDot.frame.minX - 7
        }
        // Laid out unconditionally (not gated on isHidden like its siblings) so its
        // slot is reserved and it stays correctly positioned when focus toggles it
        // visible — focus changes don't trigger a header relayout.
        if let closeButton {
            let size = closeButton.intrinsicContentSize
            closeButton.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = closeButton.frame.minX - 7
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
        if !freshMeta.isHidden {
            let size = freshMeta.fittedSize
            freshMeta.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = freshMeta.frame.minX - 7
        }
        if !ownerChip.isHidden {
            let size = ownerChip.intrinsicContentSize
            ownerChip.frame = NSRect(
                x: rightX - size.width,
                y: ((h - size.height) / 2).rounded(),
                width: size.width,
                height: size.height
            )
            rightX = ownerChip.frame.minX - 7
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
        if let closeButton, hit === closeButton { return hit }
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
        // P5.3 revive swaps a fresh view into an already-attached card. `terminal`
        // is weak, so reassigning it does NOT release the prior view — it stays
        // retained (and drawing) as a subview unless removed. Drop it first.
        if let old = self.terminal, old !== terminal { old.removeFromSuperview() }
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

