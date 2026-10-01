import AppKit
import QuartzCore
import TarmacKit

/// A top-down (flipped) container view.
@MainActor
final class FlippedColumnView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// NSTextField's intrinsicContentSize under-reports its drawn width (cell
/// insets), which triggers spurious truncation at exact-fit frames; measure
/// via sizeToFit instead.
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

/// The `✎ Ns` meta on a doc card: shown while the doc's last change is inside
/// the recency window, and re-read once a second while it is.
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
        guard let text = ChromeText.recencyLabel(lastChangedMs: lastChangedMs, nowMs: nowMs) else {
            if !isHidden {
                isHidden = true
                onUpdate?()
            }
            return
        }
        stringValue = text
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

/// A control in a card header (`✕`, `↻`). It keeps the press to itself, so a
/// click on it never selects the card or starts a drag, and acts on release
/// inside it.
@MainActor
final class HeaderButton: NSView {
    var onClick: (() -> Void)?

    private let label: NSTextField
    private var size: NSSize = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init(glyph: String, toolTip: String, fontSize: CGFloat = 10.5) {
        label = NSTextField(labelWithString: glyph)
        label.font = Theme.mono(fontSize)
        label.textColor = Theme.faint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        self.toolTip = toolTip
        addSubview(label)
        setGlyph(glyph)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Changes what the button reads, and its width with it.
    func setGlyph(_ glyph: String) {
        label.stringValue = glyph
        let textSize = label.fittedSize
        size = NSSize(width: textSize.width + 10, height: textSize.height + 2)
        setFrameSize(size)
        label.frame = NSRect(x: 5, y: 1, width: textSize.width, height: textSize.height)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override var intrinsicContentSize: NSSize { size }

    // The label would otherwise take the press itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.bg3.cgColor
        label.textColor = Theme.text
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
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
}

extension HeaderButton: HoverCursorProviding {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .pointingHand }
}

/// The `← <terminal>` chip on a doc card: at most 120 wide, the name cut at
/// the tail. Display only.
@MainActor
final class OwnerChipView: NSView {
    private static let maxWidth: CGFloat = 120
    private static let padX: CGFloat = 6
    private static let padY: CGFloat = 1

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
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setLabel(_ text: String) {
        label.stringValue = text
        let textSize = label.fittedSize
        let width = min(Self.maxWidth, textSize.width + Self.padX * 2)
        size = NSSize(width: width, height: textSize.height + Self.padY * 2)
        label.frame = NSRect(x: Self.padX, y: Self.padY, width: width - Self.padX * 2, height: textSize.height)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { size }
}

/// A card's header: the handle the card is dragged by, with what identifies
/// the card on the left and its state and controls packed against the right.
///
/// A terminal header reads `›_ label … ●`; a doc header reads
/// `¶ ● label … ← owner  ✚ now  ✎ Ns  ↻  ✕`. The buttons keep their own
/// presses; everywhere else a press is the header's.
@MainActor
final class CardHeaderView: NSView {
    enum Kind {
        case terminal
        case doc(DocKind)

        fileprivate var glyph: String {
            switch self {
            case .terminal: return "›_"
            case .doc(.markdown): return "¶"
            case .doc(.html): return "</>"
            }
        }
    }

    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?

    let closeButton: HeaderButton?
    let refreshButton: HeaderButton?

    private static let font = Theme.mono(10.5)
    private static let dotSize: CGFloat = 7

    private let hairline = NSView()
    private let kindGlyph: NSTextField
    private let repoDot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let ownerChip = OwnerChipView()
    private let freshMeta = NSTextField(labelWithString: "✚ now")
    private let recency = RecentMetaLabel(font: Theme.mono(9.5), color: Theme.agent)
    private let bellDot = NSTextField(labelWithString: "●")
    /// An extra control between `↻` and `✕`.
    private var accessory: NSView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(kind: Kind) {
        kindGlyph = NSTextField(labelWithString: kind.glyph)
        if case .doc = kind {
            refreshButton = HeaderButton(glyph: "↻", toolTip: "Refresh from disk")
            closeButton = HeaderButton(glyph: "✕", toolTip: "Close")
        } else {
            refreshButton = nil
            closeButton = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bg2.cgColor

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = Theme.lineSoft.cgColor

        kindGlyph.font = Self.font
        kindGlyph.textColor = Theme.faint

        repoDot.wantsLayer = true
        repoDot.layer?.cornerRadius = Self.dotSize / 2
        repoDot.isHidden = true

        label.font = Self.font
        label.textColor = Theme.muted
        label.lineBreakMode = .byTruncatingTail

        ownerChip.isHidden = true

        freshMeta.font = Self.font
        freshMeta.textColor = Theme.agent
        freshMeta.isHidden = true

        recency.onUpdate = { [weak self] in self?.needsLayout = true }

        bellDot.font = Self.font
        bellDot.textColor = Theme.amber
        bellDot.isHidden = true

        let controls: [NSView?] = [refreshButton, closeButton]
        for view in [hairline, kindGlyph, repoDot, label, ownerChip, freshMeta, recency, bellDot] + controls.compactMap({ $0 }) {
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Content

    func apply(doc: RestoreDoc) {
        label.stringValue = doc.fileName
        if let index = RepoDot.paletteIndex(repoColor: doc.repoColor, paletteSize: Theme.repoColors.count) {
            repoDot.layer?.backgroundColor = Theme.repoColors[index].cgColor
            repoDot.isHidden = false
        } else {
            repoDot.isHidden = true
        }
        recency.setChanged(doc.lastChangedMs)
        needsLayout = true
    }

    func setLabel(_ text: String) {
        label.stringValue = text
        needsLayout = true
    }

    func setFreshMeta(_ on: Bool) {
        guard on == freshMeta.isHidden else { return }
        freshMeta.isHidden = !on
        needsLayout = true
    }

    /// Shows `← <name>`, or hides the chip with nil.
    func setOwnerChip(_ name: String?) {
        if let name { ownerChip.setLabel("← \(name)") }
        ownerChip.isHidden = name == nil
        needsLayout = true
    }

    /// A lit bell turns the glyph amber and shows the amber dot.
    func setBell(_ on: Bool) {
        guard on == bellDot.isHidden else { return }
        bellDot.isHidden = !on
        kindGlyph.textColor = on ? Theme.amber : Theme.faint
        needsLayout = true
    }

    func setPrime(_ on: Bool) {
        layer?.backgroundColor = (on ? Theme.primeHeaderBg : Theme.bg2).cgColor
        label.textColor = on ? Theme.text : Theme.muted
    }

    func setAccessory(_ view: NSView?) {
        accessory?.removeFromSuperview()
        accessory = view
        if let view { addSubview(view) }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        hairline.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)

        let leading = [(kindGlyph, kindGlyph.fittedSize), (repoDot, NSSize(width: Self.dotSize, height: Self.dotSize))]
            .filter { !$0.0.isHidden }
        let trailingViews: [NSView?] = [ownerChip, freshMeta, recency, refreshButton, accessory, closeButton, bellDot]
        let trailing = trailingViews.compactMap { $0 }.filter { !$0.isHidden }.map { ($0, size(of: $0)) }
        let labelSize = label.fittedSize

        let frames = CardHeaderLayout.frames(
            width: bounds.width,
            leading: leading.map(\.1.width),
            label: labelSize.width,
            trailing: trailing.map(\.1.width)
        )
        for (item, span) in zip(leading, frames.leading) { place(item.0, span, height: item.1.height) }
        for (item, span) in zip(trailing, frames.trailing) { place(item.0, span, height: item.1.height) }
        place(label, frames.label, height: labelSize.height)
    }

    private func size(of view: NSView) -> NSSize {
        if let field = view as? NSTextField { return field.fittedSize }
        return view.intrinsicContentSize
    }

    /// Centred in the header above its bottom hairline.
    private func place(_ view: NSView, _ span: CardHeaderLayout.Span, height: CGFloat) {
        view.frame = NSRect(
            x: span.x,
            y: ((bounds.height - 1 - height) / 2).rounded(),
            width: span.width,
            height: height
        )
    }

    // MARK: Mouse

    // A press anywhere but on a button is the header's own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is HeaderButton ? hit : self
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
}

extension CardHeaderView: HoverCursorProviding {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .openHand }
}

/// Terminal card body: term-bg behind the terminal view, which fills it and
/// pads its own grid.
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
        // `terminal` is weak, so reassigning it does not release a view swapped
        // out of an already-attached card: it would stay a subview and keep drawing.
        if let old = self.terminal, old !== terminal { old.removeFromSuperview() }
        self.terminal = terminal
        addSubview(terminal)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        terminal?.frame = bounds
    }
}
