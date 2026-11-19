import AppKit
import TarmacKit

/// The inbox (spec 2611.0013): a panel flush right over the board area, never
/// docked. A header with the unread count, the filters and `clear all read`;
/// one row per item; the grip and the preview pane of the selected item (spec
/// 2611.0018); the keys in a footer. It draws what it is given and reports
/// clicks; the controller owns the store, the state and every key. It owns the
/// pane's height while a drag runs, and reports the height the user set.
/// Screen-space chrome: the board's zoom never scales it.
@MainActor
final class InboxPanelView: KeyHoldingView, FontFollowing, ThemeFollowing {
    struct Model: Equatable {
        let unread: Int
        let filter: Inbox.Filter
        let rows: [InboxRow]
        let selected: Inbox.ItemID?
        let preview: InboxPreview?
        let gripFocused: Bool
    }

    /// A row's id and the click count.
    var onPick: ((Inbox.ItemID, Int) -> Void)?
    var onGo: ((Inbox.ItemID) -> Void)?
    var onGripPress: (() -> Void)?
    /// The height the user set, in design points, at a drag's end, a reset
    /// or a step; nil is the standard.
    var onPaneHeight: ((Double?) -> Void)?

    /// The height the user set, as `AppPrefs` holds it.
    var paneWanted: Double? {
        didSet { if paneWanted != oldValue { needsLayout = true } }
    }
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
    private enum Font {
        static var heading: NSFont { Theme.mono(10) }
        static var count: NSFont { Theme.mono(10, weight: .semibold) }
        static var empty: NSFont { Theme.mono(10.5) }
        static var footer: NSFont { Theme.mono(10) }
    }

    private let edge = NSView()
    private let header = FlippedColumnView()
    private let headerRule = NSView()
    private let heading = OverlayLabel()
    private let count = OverlayLabel()
    private let filters = Inbox.Filter.allCases.map { InboxFilterButton(InboxCopy.filterName($0)) }
    private let clearRead = InboxFilterButton("clear all read")
    private let scroll = NSScrollView()
    private let rowsDoc = FlippedColumnView()
    private let grip = InboxSplitGrip()
    private let preview = InboxPreviewView()
    /// What the panel had for the list and the pane at the last layout.
    private var paneRoom: CGFloat = 0
    /// A drag in progress, from the wanted height it began at.
    private struct Drag {
        let start: Double?
    }

    private var drag: Drag?
    private let emptyLabel = OverlayLabel()
    private let footer = FlippedColumnView()
    private let footerRule = NSView()
    private let footerLabel = OverlayLabel()
    private var rowViews: [InboxRowView] = []
    private var model: Model?

    override var isFlipped: Bool { true }

    /// Closing the panel mid-drag ends the drag where it was.
    override var isHidden: Bool {
        didSet {
            guard isHidden, drag != nil else { return }
            grip.cancelPress()
            gripReleased()
        }
    }

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
        addSubview(grip)
        addSubview(preview)
        grip.onPress = { [weak self] count in self?.gripPressed(count) }
        grip.onDrag = { [weak self] delta in self?.gripDragged(delta) }
        grip.onRelease = { [weak self] in self?.gripReleased() }
        preview.onGo = { [weak self] in
            guard let id = self?.model?.preview?.id else { return }
            self?.onGo?(id)
        }
        footer.addSubview(footerRule)
        footer.addSubview(footerLabel)
        addSubview(edge)
        themeChanged()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func fontsChanged() {
        preview.styleChanged()
        redraw()
    }

    func themeChanged() {
        layer?.backgroundColor = Theme.bg2.cgColor
        edge.layer?.backgroundColor = Theme.line.cgColor
        for bar in [header, footer] { bar.layer?.backgroundColor = Theme.bg1.cgColor }
        for rule in [headerRule, footerRule] { rule.layer?.backgroundColor = Theme.lineSoft.cgColor }
        grip.needsDisplay = true
        preview.styleChanged()
        redraw()
    }

    /// A model like the one shown draws nothing again.
    func render(_ model: Model) {
        guard model != self.model else { return }
        self.model = model
        redraw()
    }

    /// Draws the model again: a font or a theme changed what it looks like.
    private func redraw() {
        guard let model else { return }
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

        // Row views are kept and given new rows; only the count changes.
        while rowViews.count > model.rows.count { rowViews.removeLast().removeFromSuperview() }
        while rowViews.count < model.rows.count {
            let view = InboxRowView()
            rowsDoc.addSubview(view)
            rowViews.append(view)
        }
        for (view, row) in zip(rowViews, model.rows) {
            view.configure(row, selected: row.id == model.selected)
            view.onClick = { [weak self] count in self?.onPick?(row.id, count) }
            view.onGo = { [weak self] in self?.onGo?(row.id) }
        }
        grip.focused = model.gripFocused
        preview.render(model.preview)
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
            x: Metric.padX, y: line.centered(headingSize.height, top: Metric.padY),
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

        paneRoom = max(0, footer.frame.minY - headerHeight - InboxSplitGrip.height)
        let paneHeight = InboxPreviewSplit.shown(wanted: paneWanted, room: paneRoom, scale: Theme.chrome(1))
        preview.frame = NSRect(x: 1, y: footer.frame.minY - paneHeight, width: inner, height: paneHeight)
        grip.frame = NSRect(
            x: 1, y: preview.frame.minY - InboxSplitGrip.height, width: inner, height: InboxSplitGrip.height
        )
        scroll.frame = NSRect(x: 1, y: headerHeight, width: inner, height: max(0, grip.frame.minY - headerHeight))
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

    // MARK: - The split (spec 2611.0018 D6–D8)

    /// The grip's ↑ (+1) or ↓ (−1).
    func stepPane(_ steps: Int) {
        let wanted = InboxPreviewSplit.stepped(wanted: paneWanted, steps: steps, room: paneRoom, scale: Theme.chrome(1))
        guard wanted != paneWanted else { return }
        paneWanted = wanted
        onPaneHeight?(wanted)
    }

    private func gripPressed(_ count: Int) {
        onGripPress?()
        guard count < 2 else {
            drag = nil
            paneWanted = nil
            onPaneHeight?(nil)
            return
        }
        drag = Drag(start: paneWanted)
    }

    private func gripDragged(_ delta: CGFloat) {
        guard let drag else { return }
        paneWanted = InboxPreviewSplit.dragged(wanted: drag.start, by: delta, room: paneRoom, scale: Theme.chrome(1))
    }

    private func gripReleased() {
        guard let drag else { return }
        self.drag = nil
        if paneWanted != drag.start { onPaneHeight?(paneWanted) }
    }
}
