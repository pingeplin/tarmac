import AppKit
import TarmacKit

/// The inbox (spec 2611.0013): a panel flush right over the board area, never
/// docked. A header with the unread count, the filters and `clear all read`;
/// one row per item; the keys in a footer. It draws what it is given and
/// reports clicks; the controller owns the store, the state and every key.
/// Screen-space chrome: the board's zoom never scales it.
@MainActor
final class InboxPanelView: KeyHoldingView, FontFollowing, ThemeFollowing {
    struct Row: Equatable {
        let id: Inbox.ItemID
        let kind: Inbox.Kind
        let title: String
        let quote: String?
        let place: String
        let age: String
        let read: Bool
    }

    struct Model: Equatable {
        let unread: Int
        let filter: Inbox.Filter
        let rows: [Row]
        let selected: Inbox.ItemID?
    }

    var onPick: ((Inbox.ItemID) -> Void)?
    var onFilter: ((Inbox.Filter) -> Void)?
    var onClearRead: (() -> Void)?

    private enum Metric {
        static let padX: CGFloat = 14
        static let padY: CGFloat = 10
        static let gap: CGFloat = 8
        static let chipGap: CGFloat = 6
        static let footerPadY: CGFloat = 8
        static let emptyPadY: CGFloat = 16
    }

    @MainActor
    fileprivate enum Font {
        static var heading: NSFont { Theme.mono(10) }
        static var count: NSFont { Theme.mono(10, weight: .semibold) }
        static var chip: NSFont { Theme.mono(10) }
        static var empty: NSFont { Theme.mono(10.5) }
        static var footer: NSFont { Theme.mono(10) }
    }

    private let edge = NSView()
    private let header = FlippedColumnView()
    private let headerRule = NSView()
    private let heading = InboxLabel()
    private let count = InboxLabel()
    private let filters = Inbox.Filter.allCases.map { InboxButton(InboxCopy.filterName($0)) }
    private let clearRead = InboxButton("clear all read")
    private let scroll = NSScrollView()
    private let rowsDoc = FlippedColumnView()
    private let emptyLabel = InboxLabel()
    private let footer = FlippedColumnView()
    private let footerRule = NSView()
    private let footerLabel = InboxLabel()
    private var rowViews: [InboxRowView] = []
    private var model = Model(unread: 0, filter: .all, rows: [], selected: nil)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        shadow = OverlayPalette.dropShadow(y: 0, blur: 40)
        for view in [edge, headerRule, footerRule] { view.wantsLayer = true }
        for bar in [header, footer] {
            bar.wantsLayer = true
            addSubview(bar)
        }
        header.addSubview(headerRule)
        header.addSubview(heading)
        header.addSubview(count)
        for (filter, button) in zip(Inbox.Filter.allCases, filters) {
            button.onClick = { [weak self] in self?.onFilter?(filter) }
            header.addSubview(button)
        }
        clearRead.onClick = { [weak self] in self?.onClearRead?() }
        header.addSubview(clearRead)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = rowsDoc
        addSubview(scroll)
        rowsDoc.addSubview(emptyLabel)
        footer.addSubview(footerRule)
        footer.addSubview(footerLabel)
        addSubview(edge)
        themeChanged()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func fontsChanged() {
        render(model)
    }

    func themeChanged() {
        layer?.backgroundColor = Theme.bg2.cgColor
        edge.layer?.backgroundColor = Theme.line.cgColor
        for bar in [header, footer] { bar.layer?.backgroundColor = Theme.bg1.cgColor }
        for rule in [headerRule, footerRule] { rule.layer?.backgroundColor = Theme.lineSoft.cgColor }
        render(model)
    }

    func render(_ model: Model) {
        self.model = model
        heading.attributedStringValue = NSAttributedString(
            string: "inbox", attributes: [.font: Font.heading, .foregroundColor: Theme.faint, .kern: 0.8]
        )
        count.attributedStringValue = NSAttributedString(
            string: model.unread > 0 ? "\(model.unread)" : "",
            attributes: [.font: Font.count, .foregroundColor: Theme.amber]
        )
        for (filter, button) in zip(Inbox.Filter.allCases, filters) {
            button.setActive(filter == model.filter)
        }
        clearRead.setActive(false)
        emptyLabel.attributedStringValue = NSAttributedString(
            string: InboxCopy.empty, attributes: [.font: Font.empty, .foregroundColor: Theme.faint]
        )
        footerLabel.attributedStringValue = NSAttributedString(
            string: InboxCopy.footer, attributes: [.font: Font.footer, .foregroundColor: Theme.faint]
        )

        for view in rowViews { view.removeFromSuperview() }
        rowViews = model.rows.map { row in
            let view = InboxRowView()
            view.configure(row, selected: row.id == model.selected)
            view.onClick = { [weak self] in self?.onPick?(row.id) }
            rowsDoc.addSubview(view)
            return view
        }
        emptyLabel.isHidden = !model.rows.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let selected = rowViews.first(where: \.selected) {
            selected.scrollToVisible(selected.bounds)
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let inner = width - 1
        edge.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)

        let headingSize = heading.fittedSize
        let clearSize = clearRead.fittingSize
        let line = max(headingSize.height, clearSize.height)
        heading.frame = NSRect(
            x: Metric.padX, y: Metric.padY + ((line - headingSize.height) / 2).rounded(),
            width: headingSize.width, height: headingSize.height
        )
        let countSize = count.fittedSize
        count.frame = NSRect(
            x: heading.frame.maxX + Metric.gap, y: heading.frame.minY, width: countSize.width, height: countSize.height
        )
        clearRead.frame = NSRect(
            x: inner - Metric.padX - clearSize.width, y: Metric.padY, width: clearSize.width, height: clearSize.height
        )
        var x = Metric.padX
        let chipsY = Metric.padY + line + Metric.gap
        var chipHeight: CGFloat = 0
        for button in filters {
            let size = button.fittingSize
            button.frame = NSRect(x: x, y: chipsY, width: size.width, height: size.height)
            x += size.width + Metric.chipGap
            chipHeight = max(chipHeight, size.height)
        }
        let headerHeight = chipsY + chipHeight + Metric.padY + 1
        header.frame = NSRect(x: 1, y: 0, width: inner, height: headerHeight)
        headerRule.frame = NSRect(x: 0, y: headerHeight - 1, width: inner, height: 1)

        let footerSize = footerLabel.fittedSize
        let footerHeight = 1 + Metric.footerPadY * 2 + footerSize.height
        footer.frame = NSRect(x: 1, y: bounds.height - footerHeight, width: inner, height: footerHeight)
        footerRule.frame = NSRect(x: 0, y: 0, width: inner, height: 1)
        footerLabel.frame = NSRect(
            x: Metric.padX, y: 1 + Metric.footerPadY, width: min(footerSize.width, inner - Metric.padX * 2),
            height: footerSize.height
        )

        scroll.frame = NSRect(x: 1, y: headerHeight, width: inner, height: max(0, footer.frame.minY - headerHeight))
        var y: CGFloat = 0
        for row in rowViews {
            let height = row.height()
            row.frame = NSRect(x: 0, y: y, width: inner, height: height)
            y += height
        }
        let emptySize = emptyLabel.fittedSize
        let emptyHeight = Metric.emptyPadY * 2 + emptySize.height
        rowsDoc.frame = NSRect(
            x: 0, y: 0, width: inner, height: max(rowViews.isEmpty ? emptyHeight : y, scroll.bounds.height)
        )
        emptyLabel.frame = NSRect(
            x: ((inner - emptySize.width) / 2).rounded(), y: Metric.emptyPadY,
            width: emptySize.width, height: emptySize.height
        )
    }
}

/// One item: its kind tag, title and age; the quote of a report; its place.
/// A read row's text goes faint and its tag keeps the kind's colour on its
/// border; nothing is dimmed by transparency.
@MainActor
private final class InboxRowView: NSView {
    var onClick: (() -> Void)?
    private(set) var selected = false

    private enum Metric {
        static let padX: CGFloat = 14
        static let padY: CGFloat = 8
        static let lineGap: CGFloat = 3
        static let gap: CGFloat = 8
    }

    @MainActor
    private enum Font {
        static var title: NSFont { Theme.mono(11) }
        static var quote: NSFont { Theme.mono(11) }
        static var place: NSFont { Theme.mono(10) }
        static var age: NSFont { Theme.mono(10) }
    }

    private let kindTag = ChipView()
    private let title = InboxLabel()
    private let age = InboxLabel()
    private let quote = InboxLabel()
    private let place = InboxLabel()
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for label in [title, quote, place] { label.lineBreakMode = .byTruncatingTail }
        for view in [kindTag, title, age, quote, place] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ row: InboxPanelView.Row, selected: Bool) {
        self.selected = selected
        paint()
        kindTag.setTone(.inbox(row.kind, dimmed: row.read))
        kindTag.setLabel(InboxCopy.tag(row.kind))
        let text = row.read ? Theme.faint : Theme.text
        title.attributedStringValue = NSAttributedString(
            string: row.title, attributes: [.font: Font.title, .foregroundColor: text]
        )
        age.attributedStringValue = NSAttributedString(
            string: row.age, attributes: [.font: Font.age, .foregroundColor: Theme.faint]
        )
        quote.attributedStringValue = NSAttributedString(
            string: row.quote ?? "",
            attributes: [.font: Font.quote, .foregroundColor: row.read ? Theme.faint : Theme.muted]
        )
        quote.isHidden = row.quote == nil
        place.attributedStringValue = NSAttributedString(
            string: row.place, attributes: [.font: Font.place, .foregroundColor: Theme.faint]
        )
        toolTip = ([row.title, row.quote].compactMap { $0 } + [row.place]).joined(separator: "\n")
        needsLayout = true
    }

    func height() -> CGFloat {
        let first = max(kindTag.intrinsicContentSize.height, title.fittedSize.height)
        let lines = [first, quote.isHidden ? nil : quote.fittedSize.height, place.fittedSize.height].compactMap { $0 }
        return Metric.padY * 2 + lines.reduce(0, +) + Metric.lineGap * CGFloat(lines.count - 1)
    }

    private func paint() {
        layer?.backgroundColor = (selected || hovered ? Theme.bg3 : NSColor.clear).cgColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        kindTag.apply(CardScale(zoom: 1, backing: window?.backingScaleFactor ?? 2))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let tagSize = kindTag.intrinsicContentSize
        let titleSize = title.fittedSize
        let first = max(tagSize.height, titleSize.height)
        kindTag.frame = NSRect(
            x: Metric.padX, y: Metric.padY + ((first - tagSize.height) / 2).rounded(),
            width: tagSize.width, height: tagSize.height
        )
        let ageSize = age.fittedSize
        age.frame = NSRect(
            x: width - Metric.padX - ageSize.width, y: Metric.padY + ((first - ageSize.height) / 2).rounded(),
            width: ageSize.width, height: ageSize.height
        )
        let titleX = kindTag.frame.maxX + Metric.gap
        title.frame = NSRect(
            x: titleX, y: Metric.padY + ((first - titleSize.height) / 2).rounded(),
            width: max(0, min(titleSize.width, age.frame.minX - Metric.gap - titleX)), height: titleSize.height
        )
        var y = Metric.padY + first + Metric.lineGap
        if !quote.isHidden {
            let size = quote.fittedSize
            quote.frame = NSRect(
                x: Metric.padX, y: y, width: min(size.width, width - Metric.padX * 2), height: size.height
            )
            y += size.height + Metric.lineGap
        }
        let placeSize = place.fittedSize
        place.frame = NSRect(
            x: Metric.padX, y: y, width: min(placeSize.width, width - Metric.padX * 2), height: placeSize.height
        )
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

/// A filter chip or `clear all read`: a 1 px border and mono text, as the
/// header chips are; the active filter takes the agent colour.
@MainActor
private final class InboxButton: NSView {
    var onClick: (() -> Void)?
    private let label = InboxLabel()
    private let text: String

    private enum Metric {
        static let padX: CGFloat = 6
        static let padY: CGFloat = 2
    }

    override var isFlipped: Bool { true }

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActive(_ active: Bool) {
        layer?.borderColor = (active ? Theme.agent : Theme.lineSoft).cgColor
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [.font: InboxPanelView.Font.chip, .foregroundColor: active ? Theme.agent : Theme.muted]
        )
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let size = label.fittedSize
        return NSSize(width: size.width + Metric.padX * 2, height: size.height + Metric.padY * 2)
    }

    override func layout() {
        super.layout()
        let size = label.fittedSize
        label.frame = NSRect(x: Metric.padX, y: Metric.padY, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A text run of the panel. Clicks go to whatever holds it.
@MainActor
private final class InboxLabel: NSTextField {
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
