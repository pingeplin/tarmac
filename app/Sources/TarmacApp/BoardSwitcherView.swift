import AppKit
import TarmacKit

/// The ⌘K switcher: a veil over the board area and a centered panel holding a
/// query bar, the board rows and a footer. It draws the rows and the state it
/// is given, with `SwitcherChrome`'s words, and reports clicks; the controller
/// owns the state and every key.
@MainActor
final class BoardSwitcherView: NSView {
    /// A row was clicked (its index among the visible rows).
    var onPickRow: ((Int) -> Void)?
    /// The veil outside the panel was clicked.
    var onDismiss: (() -> Void)?

    /// Who gets keyboard focus back when the switcher closes.
    weak var keysOwner: NSResponder?

    private enum Metric {
        static let panelWidth: CGFloat = 380
        static let panelMaxHeight: CGFloat = 480
        static let border: CGFloat = 1
        static let padX: CGFloat = 14
        static let gap: CGFloat = 8
        static let queryPadY: CGFloat = 10
        static let listPadY: CGFloat = 4
        static let emptyPadY: CGFloat = 16
        static let footerPadY: CGFloat = 8
        static let caretBlink: TimeInterval = 0.5
    }

    @MainActor
    private enum Font {
        static let queryLabel = Theme.mono(10)
        static let query = Theme.mono(12)
        static let empty = Theme.mono(10.5)
        static let footer = Theme.mono(10)
        static let footerStrong = Theme.mono(10, weight: .semibold)
        /// The footer's own text size, which sets its line height.
        static let panel = Theme.mono(11)
    }

    private let panel = FlippedBox()
    private let content = FlippedBox()
    private let queryBar = FlippedBox()
    private let queryRule = NSView()
    private let queryLabel = SwitcherLabel()
    private let queryClip = FlippedBox()
    private let queryText = SwitcherLabel()
    private let caret = SwitcherLabel()
    private let scroll = NSScrollView()
    private let rowsDoc = FlippedBox()
    private let emptyLabel = SwitcherLabel()
    private let footer = FlippedBox()
    private let footerRule = NSView()
    private let footerLabel = SwitcherLabel()
    private var rowViews: [BoardSwitcherRow] = []
    private var blink: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.shadowBlurRadius = 38
        panel.wantsLayer = true
        panel.shadow = shadow
        addSubview(panel)

        // The border is the clipping layer's own, so it is drawn over the
        // bars' fills, and the shadow stays on the unclipped panel behind it.
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.bg2.cgColor
        content.layer?.borderColor = Theme.line.cgColor
        content.layer?.borderWidth = Metric.border
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.addSubview(content)

        for bar in [queryBar, footer] {
            bar.wantsLayer = true
            bar.layer?.backgroundColor = Theme.bg1.cgColor
            content.addSubview(bar)
        }
        for rule in [queryRule, footerRule] {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Theme.lineSoft.cgColor
        }
        queryBar.addSubview(queryRule)
        footer.addSubview(footerRule)

        queryBar.addSubview(queryLabel)
        queryClip.wantsLayer = true
        queryClip.layer?.masksToBounds = true
        queryBar.addSubview(queryClip)
        queryClip.addSubview(queryText)
        caret.attributedStringValue = NSAttributedString(
            string: SwitcherChrome.caret, attributes: [.font: Font.query, .foregroundColor: Theme.agent]
        )
        queryClip.addSubview(caret)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = rowsDoc
        content.addSubview(scroll)

        emptyLabel.attributedStringValue = NSAttributedString(
            string: SwitcherChrome.emptyList, attributes: [.font: Font.empty, .foregroundColor: Theme.faint]
        )
        rowsDoc.addSubview(emptyLabel)

        footer.addSubview(footerLabel)

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Keyboard focus

    /// Takes first responder, remembering who had it. The view answers none
    /// of the menu's first-responder commands, so while it is up Paste, Copy
    /// and Select All do nothing instead of reaching the terminal behind it.
    func takeKeys() {
        keysOwner = window?.firstResponder
        window?.makeFirstResponder(self)
    }

    /// Hands first responder back to `keysOwner`, or to `fallback` when that
    /// view has left the window meanwhile.
    func returnKeys(fallback: NSView) {
        defer { keysOwner = nil }
        guard let window, window.firstResponder === self else { return }
        if let owner = keysOwner as? NSView, owner.window === window {
            window.makeFirstResponder(owner)
        } else {
            window.makeFirstResponder(fallback)
        }
    }

    /// A ⌘ chord the menu did not take comes back as a key-down; unanswered,
    /// it would run off the responder chain and the window would beep.
    override func keyDown(with event: NSEvent) {}

    // MARK: - Rendering

    /// `nowMs` is the wall clock, which picks a live board's glyph.
    func render(rows: [BoardSwitcher.BoardRow], state: SwitcherKeys.State, nowMs: UInt64) {
        let query = SwitcherChrome.queryBar(state)
        queryLabel.attributedStringValue = NSAttributedString(
            string: query.label,
            attributes: [.font: Font.queryLabel, .foregroundColor: Theme.faint, .kern: 0.8]
        )
        queryText.attributedStringValue = query.text.isEmpty
            ? NSAttributedString(
                string: query.placeholder,
                // The web app ships no italic face, so its italic is the
                // regular one slanted.
                attributes: [.font: Font.query, .foregroundColor: Theme.faint, .obliqueness: 0.25]
            )
            : NSAttributedString(string: query.text, attributes: [.font: Font.query, .foregroundColor: Theme.text])
        footerLabel.attributedStringValue = footerText(SwitcherChrome.footer(state, rows: rows))

        for view in rowViews { view.removeFromSuperview() }
        rowViews = rows.enumerated().map { index, row in
            let view = BoardSwitcherRow()
            view.configure(
                row: row, selected: index == state.selected,
                glyph: SwitcherChrome.liveGlyph(isLive: row.isLive, nowMs: nowMs),
                ordinal: SwitcherChrome.ordinalHint(row: index)
            )
            view.onClick = { [weak self] in self?.onPickRow?(index) }
            rowsDoc.addSubview(view)
            return view
        }
        emptyLabel.isHidden = !rows.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        if rowViews.indices.contains(state.selected) {
            let selected = rowViews[state.selected]
            selected.scrollToVisible(selected.bounds)
        }
    }

    private func footerText(_ footer: SwitcherChrome.Footer) -> NSAttributedString {
        let color: NSColor
        if case .confirmDelete = footer { color = Theme.amber } else { color = Theme.faint }
        let text = NSMutableAttributedString()
        for run in footer.runs {
            text.append(NSAttributedString(
                string: run.text,
                attributes: [.font: run.strong ? Font.footerStrong : Font.footer, .foregroundColor: color]
            ))
        }
        return text
    }

    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }

    // MARK: - Layout

    /// A line of `font` as the web app's layout measures it: each of the
    /// font's vertical metrics rounded to a whole pixel.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        font.ascender.rounded() + (-font.descender).rounded() + font.leading.rounded()
    }

    override func layout() {
        super.layout()
        let width = Metric.panelWidth - Metric.border * 2
        let queryHeight = Metric.queryPadY * 2 + Self.lineHeight(Font.query) + 1
        let footerHeight = 1 + Metric.footerPadY * 2 + Self.lineHeight(Font.panel)
        let rowHeight = BoardSwitcherRow.height
        let emptyHeight = Metric.emptyPadY * 2 + Self.lineHeight(Font.empty)
        let listContent = Metric.listPadY * 2 + (rowViews.isEmpty ? emptyHeight : CGFloat(rowViews.count) * rowHeight)
        let listHeight = min(listContent, Metric.panelMaxHeight - Metric.border * 2 - queryHeight - footerHeight)
        let height = Metric.border * 2 + queryHeight + listHeight + footerHeight

        panel.frame = NSRect(
            x: ((bounds.width - Metric.panelWidth) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
            width: Metric.panelWidth, height: height
        )
        content.frame = panel.bounds
        let inner = content.bounds.insetBy(dx: Metric.border, dy: Metric.border)

        queryBar.frame = NSRect(x: inner.minX, y: inner.minY, width: width, height: queryHeight)
        queryRule.frame = NSRect(x: 0, y: queryHeight - 1, width: width, height: 1)
        let labelSize = queryLabel.fittedSize
        queryLabel.frame = NSRect(
            x: Metric.padX, y: ((queryHeight - 1 - labelSize.height) / 2).rounded(),
            width: labelSize.width, height: labelSize.height
        )
        let textSize = queryText.fittedSize
        let caretSize = caret.fittedSize
        let clipX = queryLabel.frame.maxX + Metric.gap
        let clipHeight = max(textSize.height, caretSize.height)
        queryClip.frame = NSRect(
            x: clipX, y: ((queryHeight - 1 - clipHeight) / 2).rounded(),
            width: max(0, width - Metric.padX - clipX), height: clipHeight
        )
        queryText.frame = NSRect(origin: .zero, size: textSize)
        caret.frame = NSRect(x: textSize.width, y: 0, width: caretSize.width, height: caretSize.height)

        scroll.frame = NSRect(x: inner.minX, y: queryBar.frame.maxY, width: width, height: listHeight)
        rowsDoc.frame = NSRect(x: 0, y: 0, width: width, height: listContent)
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(x: 0, y: Metric.listPadY + CGFloat(index) * rowHeight, width: width, height: rowHeight)
        }
        let emptySize = emptyLabel.fittedSize
        emptyLabel.frame = NSRect(
            x: ((width - emptySize.width) / 2).rounded(),
            y: Metric.listPadY + ((emptyHeight - emptySize.height) / 2).rounded(),
            width: emptySize.width, height: emptySize.height
        )

        footer.frame = NSRect(x: inner.minX, y: scroll.frame.maxY, width: width, height: footerHeight)
        footerRule.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        let footerSize = footerLabel.fittedSize
        footerLabel.frame = NSRect(
            x: Metric.padX, y: 1 + ((footerHeight - 1 - footerSize.height) / 2).rounded(),
            width: min(footerSize.width, width - Metric.padX * 2), height: footerSize.height
        )
    }

    // MARK: - Caret

    override func viewDidUnhide() {
        super.viewDidUnhide()
        caret.alphaValue = 1
        let timer = Timer(timeInterval: Metric.caretBlink, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let caret = self?.caret else { return }
                caret.alphaValue = caret.alphaValue == 0 ? 1 : 0
            }
        }
        // Common modes, so the caret keeps blinking while a menu is tracked.
        RunLoop.main.add(timer, forMode: .common)
        blink?.invalidate()
        blink = timer
    }

    override func viewDidHide() {
        super.viewDidHide()
        blink?.invalidate()
        blink = nil
    }
}

/// One board row: the live glyph, the name (teal, with a mark, for the active
/// board), the counts and the ⌘n hint. Clicking it switches to that board.
@MainActor
final class BoardSwitcherRow: NSView {
    var onClick: (() -> Void)?

    private enum Metric {
        static let padX: CGFloat = 14
        static let padY: CGFloat = 7
        static let gap: CGFloat = 8
        static let glyphWidth: CGFloat = 12
        static let markGap: CGFloat = 4
    }

    @MainActor
    private enum Font {
        static let glyph = Theme.mono(11)
        static let name = Theme.mono(11.5)
        static let mark = Theme.mono(8)
        static let meta = Theme.mono(10)
        static let ordinal = Theme.mono(9.5)
    }

    static var height: CGFloat { Metric.padY * 2 + BoardSwitcherView.lineHeight(Font.name) }

    private let glyphLabel = SwitcherLabel()
    private let nameLabel = SwitcherLabel()
    private let metaLabel = SwitcherLabel()
    private let ordinalLabel = SwitcherLabel()
    private var selected = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        nameLabel.lineBreakMode = .byTruncatingTail
        for label in [glyphLabel, nameLabel, metaLabel, ordinalLabel] {
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(row: BoardSwitcher.BoardRow, selected: Bool, glyph: String, ordinal: String?) {
        self.selected = selected
        paint()

        glyphLabel.attributedStringValue = NSAttributedString(
            string: glyph,
            attributes: [.font: Font.glyph, .foregroundColor: row.isLive ? Theme.agent : Theme.faint]
        )
        let name = NSMutableAttributedString(
            string: row.display,
            attributes: [.font: Font.name, .foregroundColor: row.isActive ? Theme.agent : Theme.text]
        )
        if row.isActive {
            // The mark is smaller than the name and sits on its middle.
            name.append(NSAttributedString(string: " ", attributes: [.font: Font.mark, .kern: Metric.markGap]))
            name.append(NSAttributedString(
                string: SwitcherChrome.activeMark,
                attributes: [.font: Font.mark, .foregroundColor: Theme.agent, .baselineOffset: 1.5]
            ))
        }
        nameLabel.attributedStringValue = name
        metaLabel.attributedStringValue = NSAttributedString(
            string: row.meta, attributes: [.font: Font.meta, .foregroundColor: Theme.faint]
        )
        ordinalLabel.attributedStringValue = NSAttributedString(
            string: ordinal ?? "", attributes: [.font: Font.ordinal, .foregroundColor: Theme.line]
        )
        ordinalLabel.isHidden = ordinal == nil
        needsLayout = true
    }

    private func paint() {
        layer?.backgroundColor = (selected || hovered ? Theme.bg3 : NSColor.clear).cgColor
    }

    override func layout() {
        super.layout()
        func centered(_ size: NSSize, x: CGFloat, width: CGFloat? = nil) -> NSRect {
            NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: width ?? size.width, height: size.height)
        }
        glyphLabel.frame = centered(glyphLabel.fittedSize, x: Metric.padX)

        var right = bounds.width - Metric.padX
        if !ordinalLabel.isHidden {
            let size = ordinalLabel.fittedSize
            ordinalLabel.frame = centered(size, x: right - size.width)
            right = ordinalLabel.frame.minX - Metric.gap
        }
        let metaSize = metaLabel.fittedSize
        metaLabel.frame = centered(metaSize, x: right - metaSize.width)
        right = metaLabel.frame.minX - Metric.gap

        let nameX = Metric.padX + Metric.glyphWidth + Metric.gap
        let nameSize = nameLabel.fittedSize
        nameLabel.frame = centered(nameSize, x: nameX, width: max(0, min(nameSize.width, right - nameX)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        paint()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A text run of the panel. Clicks go to whatever holds it.
@MainActor
private final class SwitcherLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        lineBreakMode = .byClipping
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A container whose y runs down, like the rest of the chrome.
@MainActor
private final class FlippedBox: NSView {
    override var isFlipped: Bool { true }
}
