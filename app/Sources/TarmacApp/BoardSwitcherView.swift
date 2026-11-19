import AppKit
import TarmacKit

/// The ⌘K switcher: a veil over the board area and a centered panel holding a
/// query bar, the board rows and a footer. It draws the rows and the state it
/// is given, with `SwitcherChrome`'s words, and reports clicks; the controller
/// owns the state and every key.
@MainActor
final class BoardSwitcherView: KeyHoldingView, FontFollowing, ThemeFollowing {
    /// A row was clicked (its index among the visible rows).
    var onPickRow: ((Int) -> Void)?
    /// The veil outside the panel was clicked.
    var onDismiss: (() -> Void)?

    @MainActor
    private enum Metric {
        static var panelWidth: CGFloat { Theme.chrome(380) }
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
        static var queryLabel: NSFont { Theme.mono(10) }
        static var query: NSFont { Theme.mono(12) }
        static var empty: NSFont { Theme.mono(10.5) }
        static var footer: NSFont { Theme.mono(10) }
        static var footerStrong: NSFont { Theme.mono(10, weight: .semibold) }
        /// The footer's own text size, which sets its line height.
        static var panel: NSFont { Theme.mono(11) }
    }

    private let panel = FlippedColumnView()
    private let content = FlippedColumnView()
    private let queryBar = FlippedColumnView()
    private let queryRule = NSView()
    private let queryLabel = OverlayLabel()
    private let queryClip = FlippedColumnView()
    private let queryText = OverlayLabel()
    private let caret = OverlayLabel()
    private let scroll = NSScrollView()
    private let rowsDoc = FlippedColumnView()
    private let emptyLabel = OverlayLabel()
    private let footer = FlippedColumnView()
    private let footerRule = NSView()
    private let footerLabel = OverlayLabel()
    private var rowViews: [BoardSwitcherRow] = []
    private var blink: Timer?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor

        panel.wantsLayer = true
        panel.shadow = OverlayPalette.dropShadow(y: 16, blur: 76)
        addSubview(panel)

        // The border is the clipping layer's own, so it is drawn over the
        // bars' fills, and the shadow stays on the unclipped panel behind it.
        content.wantsLayer = true
        content.layer?.borderWidth = Metric.border
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        panel.addSubview(content)

        for bar in [queryBar, footer] {
            bar.wantsLayer = true
            content.addSubview(bar)
        }
        for rule in [queryRule, footerRule] { rule.wantsLayer = true }
        queryBar.addSubview(queryRule)
        footer.addSubview(footerRule)

        queryBar.addSubview(queryLabel)
        queryClip.wantsLayer = true
        queryClip.layer?.masksToBounds = true
        queryBar.addSubview(queryClip)
        queryClip.addSubview(queryText)
        themeChanged()
        queryClip.addSubview(caret)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = rowsDoc
        content.addSubview(scroll)

        rowsDoc.addSubview(emptyLabel)

        footer.addSubview(footerLabel)

        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Rendering

    /// The two texts no `render` sets again.
    private func setFixedText() {
        caret.attributedStringValue = NSAttributedString(
            string: SwitcherChrome.caret, attributes: [.font: Font.query, .foregroundColor: Theme.agent]
        )
        emptyLabel.attributedStringValue = NSAttributedString(
            string: SwitcherChrome.emptyList, attributes: [.font: Font.empty, .foregroundColor: Theme.faint]
        )
    }

    /// The rows and the query are set again by the next `render`.
    func fontsChanged() {
        setFixedText()
        needsLayout = true
    }

    /// The rows, the query and the footer take their colours at the next
    /// `render`, which an open switcher is given at once.
    func themeChanged() {
        content.layer?.backgroundColor = Theme.bg2.cgColor
        content.layer?.borderColor = Theme.line.cgColor
        for bar in [queryBar, footer] { bar.layer?.backgroundColor = Theme.bg1.cgColor }
        for rule in [queryRule, footerRule] { rule.layer?.backgroundColor = Theme.lineSoft.cgColor }
        setFixedText()
    }

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
            view.onClick = { [weak self] _ in self?.onPickRow?(index) }
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

    override func layout() {
        super.layout()
        let width = Metric.panelWidth - Metric.border * 2
        let queryHeight = Metric.queryPadY * 2 + Font.query.normalLineHeight + 1
        let footerHeight = 1 + Metric.footerPadY * 2 + Font.panel.normalLineHeight
        let rowHeight = BoardSwitcherRow.height
        let emptyHeight = Metric.emptyPadY * 2 + Font.empty.normalLineHeight
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
final class BoardSwitcherRow: OverlayRowView {
    private enum Metric {
        static let padX: CGFloat = 14
        static let padY: CGFloat = 7
        static let gap: CGFloat = 8
        static let glyphWidth: CGFloat = 12
        static let markGap: CGFloat = 4
    }

    @MainActor
    private enum Font {
        static var glyph: NSFont { Theme.mono(11) }
        static var name: NSFont { Theme.mono(11.5) }
        static var mark: NSFont { Theme.mono(8) }
        static var meta: NSFont { Theme.mono(10) }
        static var ordinal: NSFont { Theme.mono(9.5) }
    }

    static var height: CGFloat { Metric.padY * 2 + Font.name.normalLineHeight }

    private let glyphLabel = OverlayLabel()
    private let nameLabel = OverlayLabel()
    private let metaLabel = OverlayLabel()
    private let ordinalLabel = OverlayLabel()

    override init() {
        super.init()
        nameLabel.lineBreakMode = .byTruncatingTail
        for label in [glyphLabel, nameLabel, metaLabel, ordinalLabel] {
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(row: BoardSwitcher.BoardRow, selected: Bool, glyph: String, ordinal: String?) {
        self.selected = selected

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

    override func layout() {
        super.layout()
        func centered(_ size: NSSize, x: CGFloat, width: CGFloat? = nil) -> NSRect {
            NSRect(x: x, y: bounds.height.centered(size.height), width: width ?? size.width, height: size.height)
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
}
