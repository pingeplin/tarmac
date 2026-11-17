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

    init(font: NSFont) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        self.font = font
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
        let nowMs = WallClock.nowMs
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

/// A view that keeps a press to itself and calls `onClick` on its release
/// inside it, with no tracking loop of its own: a press on one never selects a
/// card, clears the selection or starts a drag (`CardPress.headerControl`). A
/// container whose hit test claims presses passes a hit on one through.
@MainActor
class PressControl: NSView {
    var onClick: (() -> Void)?

    /// Whether a press here is the control's; false lets it fall through.
    var takesPress: Bool { true }

    override var acceptsFirstResponder: Bool { false }

    // A label inside would otherwise take the press itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        takesPress && super.hitTest(point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

extension PressControl: HoverCursorProviding {
    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .pointingHand }
}

/// A control in a card header (`✕`, `↻`). It keeps the press to itself, so a
/// click on it never selects the card or starts a drag, and acts on release
/// inside it.
@MainActor
final class HeaderButton: PressControl, ThemeFollowing {
    private static let padX: CGFloat = 5
    private static let padY: CGFloat = 1
    private static let cornerRadius: CGFloat = 4

    private let label: NSTextField
    private let fontSize: CGFloat
    private var scale = CardScale(zoom: 1, backing: 2)
    private var size: NSSize = .zero
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(glyph: String, toolTip: String, fontSize: CGFloat = 10.5) {
        label = NSTextField(labelWithString: glyph)
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        self.toolTip = toolTip
        addSubview(label)
        paint()
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

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        paint()
    }

    private func paint() {
        layer?.backgroundColor = hovered ? Theme.bg3.cgColor : nil
        label.textColor = hovered ? Theme.text : Theme.faint
    }

    func themeChanged() {
        paint()
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

/// The world metrics of a chip, shared by the header's chips and a terminal
/// card's offer strip, so card chrome looks the same everywhere.
enum ChipMetrics {
    static let padX: CGFloat = 6
    static let padY: CGFloat = 1
    static let fontSize: CGFloat = 9
    static let cornerRadius: CGFloat = 4
}

/// A header chip: a 1 px border and mono text, no fill, at most 120 wide with
/// the text cut at the tail. The doc card's `← <terminal>` chip is neutral; a
/// terminal's report chip takes its kind's colour (spec 2611.0009), so one
/// form reads the same on every card kind. Display only, unless it is given an
/// action: the `resume` chip and a resume panel's buttons (2611.0015) act on a
/// release inside them, as `HeaderButton` does.
@MainActor
final class ChipView: PressControl, ThemeFollowing, FontFollowing {
    enum Tone: Equatable {
        case neutral
        /// A report chip or an inbox row's kind tag (2611.0013). A dimmed
        /// (read) one keeps the signal's colour on its border, so a read
        /// `blocked` and a read `done` still differ; its text goes faint.
        case signal(CardSignal, dimmed: Bool)
    }

    private static let maxWidth: CGFloat = 120

    private let label = NSTextField(labelWithString: "")
    private var size: NSSize = .zero
    private var scale = CardScale(zoom: 1, backing: 2)
    private var tone = Tone.neutral

    /// A chip with no `onClick` takes no press, so it is never hit and sets
    /// no cursor.
    override var takesPress: Bool { onClick != nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themeChanged()
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        apply(scale)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        switch tone {
        case .neutral:
            layer?.borderColor = Theme.lineSoft.cgColor
            label.textColor = Theme.faint
        case .signal(let signal, let dimmed):
            paint(OverlayPalette.tone(signal), dimmed: dimmed)
        }
    }

    private func paint(_ color: NSColor, dimmed: Bool) {
        layer?.borderColor = color.cgColor
        label.textColor = dimmed ? Theme.faint : color
    }

    func setTone(_ tone: Tone) {
        guard tone != self.tone else { return }
        self.tone = tone
        themeChanged()
    }

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

    func fontsChanged() {
        apply(scale)
        superview?.needsLayout = true
    }

    private func measure() {
        label.font = Theme.mono(scale.length(ChipMetrics.fontSize))
        layer?.cornerRadius = scale.length(ChipMetrics.cornerRadius)
        layer?.borderWidth = scale.line(1)
        let text = label.headerMetrics(zoom: scale.zoom)
        let padX = scale.length(ChipMetrics.padX)
        let padY = scale.length(ChipMetrics.padY)
        let overhang = CardHeaderLayout.textOverhang(scale: scale.zoom)
        let natural = text.room + 2 * padX
        let width = min(scale.length(Theme.chrome(Self.maxWidth)), natural)
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
/// A terminal header reads `›_ label … resume  report · 2m ●`; a doc header reads
/// `¶ ● label … ← owner  ✚ now  ✎ Ns  ↻  ✕`. The buttons keep their own
/// presses; everywhere else a press is the header's.
///
/// The header is laid out at its size on screen: every font and metric takes
/// the board's zoom, and its items sit on whole device pixels.
@MainActor
final class CardHeaderView: NSView, FontFollowing, ThemeFollowing {
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
    private var prime = false
    /// The doc's place in `Theme.repoColors`, or nil for no dot.
    private var repoColor: Int?

    private let hairline = NSView()
    private let kindGlyph: NSTextField
    private let repoDot = NSView()
    private let label = NSTextField(labelWithString: "")
    private let ownerChip = ChipView()
    private let reportChip = ChipView()
    /// 2611.0015 D12: copies the terminal's recorded resume command.
    let resumeChip = ChipView()
    private var resumeChipModel: ResumeHeaderChip.Model?
    private var report: TermReport?
    private var reportTick: DispatchWorkItem?
    /// The report chip's tool tip is the header's: a press anywhere but on a
    /// button is the header's own, so the chip is never the view hit.
    private var reportToolTip: String?
    private var reportToolTipTag: NSView.ToolTipTag?
    /// The chip frame the tool tip was last registered for; nil for none.
    private var reportToolTipRect: NSRect?
    private let freshMeta = NSTextField(labelWithString: "✚ now")
    private let recency = RecentMetaLabel(font: Theme.mono(recencyFontSize))
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
        hairline.wantsLayer = true
        repoDot.wantsLayer = true
        repoDot.isHidden = true
        label.lineBreakMode = .byTruncatingTail
        ownerChip.isHidden = true
        reportChip.isHidden = true
        resumeChip.isHidden = true
        freshMeta.isHidden = true
        recency.onUpdate = { [weak self] in self?.needsLayout = true }
        bellDot.isHidden = true
        paint()

        let controls: [NSView?] = [refreshButton, closeButton]
        let views = [hairline, kindGlyph, repoDot, label, ownerChip, freshMeta, recency, resumeChip, reportChip, bellDot]
        for view in views + controls.compactMap({ $0 }) {
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
        reportChip.apply(scale)
        resumeChip.apply(scale)
        refreshButton?.apply(scale)
        (accessory as? HeaderButton)?.apply(scale)
        closeButton?.apply(scale)
        needsLayout = true
    }

    func fontsChanged() {
        applyScale()
    }

    func themeChanged() {
        paint()
    }

    /// Every colour of the header, for the prime, bell and repo it has now.
    private func paint() {
        layer?.backgroundColor = (prime ? Theme.primeHeaderBg : Theme.bg2).cgColor
        label.textColor = prime ? Theme.text : Theme.muted
        hairline.layer?.backgroundColor = Theme.lineSoft.cgColor
        kindGlyph.textColor = bellDot.isHidden ? Theme.faint : Theme.amber
        bellDot.textColor = Theme.amber
        freshMeta.textColor = Theme.agent
        recency.textColor = Theme.agent
        repoDot.layer?.backgroundColor = repoColor.map { Theme.repoColors[$0].cgColor }
    }

    /// The face of the glyph, the label and the marks, at the current scale. A
    /// field takes it when it is laid out, so a hidden one costs nothing while
    /// the board zooms.
    private var font = Theme.mono(fontSize)

    private var hairlineWidth: CGFloat { scale.line(1) }

    // MARK: Content

    func apply(doc: RestoreDoc) {
        label.stringValue = doc.fileName
        repoColor = RepoDot.paletteIndex(repoColor: doc.repoColor, paletteSize: Theme.repoColors.count)
        repoDot.isHidden = repoColor == nil
        paint()
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

    /// Shows a terminal's report as `report · <age>`, or hides the chip with nil.
    /// A shown chip reads its age again every `ReportChip.refreshInterval`.
    func setReport(_ report: TermReport?) {
        guard report != nil || self.report != nil else { return }
        self.report = report
        refreshReport()
    }

    private func refreshReport() {
        reportTick?.cancel()
        reportTick = nil
        guard let report else {
            reportChip.isHidden = true
            reportToolTip = nil
            needsLayout = true
            return
        }
        let model = ReportChip.model(report: report, nowMs: WallClock.nowMs)
        reportChip.setTone(.signal(model.signal, dimmed: model.dimmed))
        reportToolTip = model.toolTip
        reportChip.isHidden = false
        reportChip.setLabel(model.text)
        needsLayout = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshReport() }
        }
        reportTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ReportChip.refreshInterval, execute: work)
    }

    /// Shows the `resume` chip with the whole command as its tool tip, or
    /// hides it with nil. A click on it calls `onClick`; a model already shown
    /// takes only the new `onClick`.
    func setResumeChip(_ model: ResumeHeaderChip.Model?, onClick: @escaping () -> Void) {
        resumeChip.onClick = model == nil ? nil : onClick
        guard model != resumeChipModel else { return }
        resumeChipModel = model
        guard let model else {
            resumeChip.isHidden = true
            needsLayout = true
            return
        }
        resumeChip.toolTip = model.toolTip
        resumeChip.isHidden = false
        resumeChip.setLabel(model.text)
        needsLayout = true
    }

    /// A lit bell turns the glyph amber and shows the amber dot.
    func setBell(_ on: Bool) {
        guard on == bellDot.isHidden else { return }
        bellDot.isHidden = !on
        paint()
        needsLayout = true
    }

    func setPrime(_ on: Bool) {
        prime = on
        paint()
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
        let trailingViews: [NSView?] = [
            ownerChip, freshMeta, recency, refreshButton, accessory, closeButton, resumeChip, reportChip, bellDot,
        ]
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
        let rect = reportChip.isHidden ? nil : reportChip.frame
        if rect != reportToolTipRect {
            if let tag = reportToolTipTag { removeToolTip(tag) }
            reportToolTipTag = rect.map { addToolTip($0, owner: self, userData: nil) }
            reportToolTipRect = rect
        }
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

    // A press anywhere but on a control is the header's own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit as? PressControl ?? self
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

/// A card's scroll thumb: where its content is scrolled to, and a handle on
/// it. It answers no hit test of its own: the card hands it a press while it
/// can be grabbed (`CardHit`), so a thumb that has faded is not there.
@MainActor
final class ScrollThumbView: NSView, ThemeFollowing {
    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onWheel: ((NSEvent) -> Void)?
    /// Whether the body under the thumb is a web view, which sets a cursor of
    /// its own on a move it is handed.
    var liesOverADoc = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themeChanged()
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        layer?.backgroundColor = Theme.scrollThumb.cgColor
        layer?.borderColor = Theme.scrollThumbLine.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseDown(with event: NSEvent) { onPress?(event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    /// The card reads the release off the application's events: a thumb
    /// hidden under its press is sent none.
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { onWheel?(event) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
    }

    /// The hairline is one device pixel, on whichever display.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

extension ScrollThumbView: HoverCursorProviding {
    var claimsPointerMoves: Bool { liesOverADoc }

    func hoverCursor(at windowPoint: NSPoint) -> NSCursor { .arrow }
}

/// Terminal card body: term-bg behind the terminal view, which fills it and
/// pads its own grid.
@MainActor
final class TerminalBodyView: NSView, ThemeFollowing {
    private(set) weak var terminal: NSView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        themeChanged()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func themeChanged() {
        layer?.backgroundColor = Theme.termBg.cgColor
    }

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

extension CardHeaderView: NSViewToolTipOwner {
    nonisolated func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated { reportToolTip ?? "" }
    }
}
