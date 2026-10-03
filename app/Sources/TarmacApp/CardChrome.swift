import AppKit
import QuartzCore
import TarmacKit

extension NSView {
    /// This view if it is a `T`, else the nearest ancestor that is.
    func enclosing<T: NSView>(_ type: T.Type) -> T? {
        var view: NSView? = self
        while let current = view {
            if let match = current as? T { return match }
            view = current.superview
        }
        return nil
    }
}

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

    /// The field's own size and the room it takes in a card header at `zoom`,
    /// from one measurement of its text. `fittedSize` would give the size too,
    /// but lays the text out again, and every header on the board is measured
    /// on each frame of a zoom.
    func headerMetrics(zoom: CGFloat) -> HeaderTextMetrics {
        let text = attributedStringValue.size()
        return HeaderTextMetrics(
            room: CardHeaderLayout.textItemWidth(text: text.width, scale: zoom),
            size: NSSize(width: CardHeaderLayout.textFieldWidth(text: text.width), height: text.height)
        )
    }
}

struct HeaderTextMetrics {
    /// The room the field takes in the row.
    let room: CGFloat
    /// The field's own size, wider than its room by the padding the zoom does
    /// not scale.
    let size: NSSize
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

    private static let padX: CGFloat = 5
    private static let padY: CGFloat = 1
    private static let cornerRadius: CGFloat = 4

    private let label: NSTextField
    private let fontSize: CGFloat
    private var scale = CardScale(zoom: 1, backing: 2)
    private var size: NSSize = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    init(glyph: String, toolTip: String, fontSize: CGFloat = 10.5) {
        label = NSTextField(labelWithString: glyph)
        label.textColor = Theme.faint
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        self.toolTip = toolTip
        addSubview(label)
        apply(scale)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Changes what the button reads, and its width with it.
    func setGlyph(_ glyph: String) {
        label.stringValue = glyph
        apply(scale)
        superview?.needsLayout = true
    }

    /// Sizes the button for the board's zoom: its glyph, padding and corners.
    func apply(_ scale: CardScale) {
        self.scale = scale
        label.font = Theme.mono(scale.length(fontSize))
        let text = label.headerMetrics(zoom: scale.zoom)
        let padX = scale.length(Self.padX)
        let padY = scale.length(Self.padY)
        // The height on whole device pixels: the label is placed from the
        // bottom edge, which has to be on one for the text to be.
        size = NSSize(width: text.room + 2 * padX, height: scale.aligned(text.size.height + 2 * padY))
        label.frame = NSRect(
            x: scale.aligned(padX - CardHeaderLayout.textOverhang(scale: scale.zoom)),
            y: scale.aligned(padY),
            width: text.size.width,
            height: text.size.height
        )
        layer?.cornerRadius = scale.length(Self.cornerRadius)
        invalidateIntrinsicContentSize()
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
    private static let fontSize: CGFloat = 9
    private static let cornerRadius: CGFloat = 4

    private let label = NSTextField(labelWithString: "")
    private var size: NSSize = .zero
    private var scale = CardScale(zoom: 1, backing: 2)

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderColor = Theme.lineSoft.cgColor
        label.textColor = Theme.faint
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        apply(scale)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setLabel(_ text: String) {
        label.stringValue = text
        measure()
    }

    /// Sizes the chip for the board's zoom: its text, padding, border and
    /// corners. A hidden chip only notes the scale, and is sized when it is
    /// next given a label to show.
    func apply(_ scale: CardScale) {
        self.scale = scale
        if !isHidden { measure() }
    }

    private func measure() {
        label.font = Theme.mono(scale.length(Self.fontSize))
        layer?.cornerRadius = scale.length(Self.cornerRadius)
        layer?.borderWidth = scale.line(1)
        let text = label.headerMetrics(zoom: scale.zoom)
        let padX = scale.length(Self.padX)
        let padY = scale.length(Self.padY)
        let overhang = CardHeaderLayout.textOverhang(scale: scale.zoom)
        let natural = text.room + 2 * padX
        let width = min(scale.length(Self.maxWidth), natural)
        size = NSSize(width: width, height: scale.aligned(text.size.height + 2 * padY))
        label.frame = NSRect(
            x: scale.aligned(padX - overhang),
            y: scale.aligned(padY),
            width: width < natural ? width - 2 * padX + 2 * overhang : text.size.width,
            height: text.size.height
        )
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
///
/// The header is laid out at its size on screen: every font and metric takes
/// the board's zoom, and its items sit on whole device pixels.
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

    private static let fontSize: CGFloat = 10.5
    private static let recencyFontSize: CGFloat = 9.5
    private static let dotSize: CGFloat = 7

    private var scale = CardScale(zoom: 1, backing: 2)

    private let hairline = NSView()
    private let kindGlyph: NSTextField
    private let repoDot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let ownerChip = OwnerChipView()
    private let freshMeta = NSTextField(labelWithString: "✚ now")
    private let recency = RecentMetaLabel(font: Theme.mono(recencyFontSize), color: Theme.agent)
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

        kindGlyph.textColor = Theme.faint

        repoDot.wantsLayer = true
        repoDot.isHidden = true

        label.textColor = Theme.muted
        label.lineBreakMode = .byTruncatingTail

        ownerChip.isHidden = true

        freshMeta.textColor = Theme.agent
        freshMeta.isHidden = true

        recency.onUpdate = { [weak self] in self?.needsLayout = true }

        bellDot.textColor = Theme.amber
        bellDot.isHidden = true

        let controls: [NSView?] = [refreshButton, closeButton]
        for view in [hairline, kindGlyph, repoDot, label, ownerChip, freshMeta, recency, bellDot] + controls.compactMap({ $0 }) {
            addSubview(view)
        }
        applyScale()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Scale

    /// Sizes the header for the board's zoom and the display's density.
    func apply(_ scale: CardScale) {
        guard scale != self.scale else { return }
        self.scale = scale
        applyScale()
    }

    private func applyScale() {
        font = Theme.mono(scale.length(Self.fontSize))
        recency.font = Theme.mono(scale.length(Self.recencyFontSize))
        repoDot.layer?.cornerRadius = scale.length(Self.dotSize) / 2
        ownerChip.apply(scale)
        refreshButton?.apply(scale)
        (accessory as? HeaderButton)?.apply(scale)
        closeButton?.apply(scale)
        needsLayout = true
    }

    /// The face of the glyph, the label and the marks, at the current scale. A
    /// field takes it when it is laid out, so a hidden one costs nothing while
    /// the board zooms.
    private var font = Theme.mono(fontSize)

    private var hairlineWidth: CGFloat { scale.line(1) }

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
        ownerChip.isHidden = name == nil
        if let name { ownerChip.setLabel("← \(name)") }
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
        (view as? HeaderButton)?.apply(scale)
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        hairline.frame = NSRect(x: 0, y: bounds.height - hairlineWidth, width: bounds.width, height: hairlineWidth)

        let dot = scale.length(Self.dotSize)
        let leading = [item(kindGlyph), Item(view: repoDot, room: dot, size: NSSize(width: dot, height: dot))]
            .filter { !$0.view.isHidden }
        let trailingViews: [NSView?] = [ownerChip, freshMeta, recency, refreshButton, accessory, closeButton, bellDot]
        let trailing = trailingViews.compactMap { $0 }.filter { !$0.isHidden }.map(item)
        let title = item(label)

        let frames = CardHeaderLayout.frames(
            width: bounds.width,
            leading: leading.map(\.room),
            label: title.room,
            trailing: trailing.map(\.room),
            scale: scale.zoom
        )
        for (item, span) in zip(leading, frames.leading) { place(item, at: span.x) }
        for (item, span) in zip(trailing, frames.trailing) { place(item, at: span.x) }
        // The label alone can be given less room than it takes, and is cut to it.
        place(title, at: frames.label.x, cutTo: frames.label.width < title.room ? frames.label.width : nil)
    }

    private struct Item {
        let view: NSView
        /// The room it takes in the row.
        let room: CGFloat
        /// Its own size: for text, wider than its room by the padding the zoom
        /// did not scale.
        let size: NSSize
    }

    private func item(_ view: NSView) -> Item {
        guard let field = view as? NSTextField else {
            let size = view.intrinsicContentSize
            return Item(view: view, room: size.width, size: size)
        }
        if field !== recency, field.font != font { field.font = font }
        let text = field.headerMetrics(zoom: scale.zoom)
        return Item(view: field, room: text.room, size: text.size)
    }

    /// Centred in the header above its bottom hairline, its origin on a whole
    /// device pixel so its text is not drawn between two.
    private func place(_ item: Item, at x: CGFloat, cutTo room: CGFloat? = nil) {
        let overhang = item.view is NSTextField ? CardHeaderLayout.textOverhang(scale: scale.zoom) : 0
        item.view.frame = NSRect(
            x: scale.aligned(x - overhang),
            y: scale.aligned((bounds.height - hairlineWidth - item.size.height) / 2),
            width: room.map { $0 + 2 * overhang } ?? item.size.width,
            height: item.size.height
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
        self.terminal = terminal
        addSubview(terminal)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        terminal?.frame = bounds
    }
}
