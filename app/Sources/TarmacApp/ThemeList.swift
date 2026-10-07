import AppKit
import TarmacKit

/// The list of the Theme pane (specs 2610.0008, 2610.0009): a row for each
/// theme it is given, in that order, with a swatch, the title and a mark for
/// each appearance the theme is chosen for. It reports the row that was
/// selected; what a selected theme does is not its concern.
@MainActor
final class ThemeList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 260
    /// The list is never less tall than the rows of the themes Tarmac
    /// ships.
    private static let minimumRows = ThemeCatalog.all.count

    private var themes: [ThemeCatalog.Entry]
    private let table = NSTableView()
    private var marks: [[ThemeVariant]]
    let view = NSScrollView()
    var onSelect: ((ThemeCatalog.Entry) -> Void)?

    init(themes: [ThemeCatalog.Entry]) {
        self.themes = themes
        marks = themes.map { _ in [] }
        super.init()
        table.style = .inset
        table.headerView = nil
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.rowHeight = 24
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("theme")))
        // The sidebar is a table too: a QA script tells the two apart by
        // this.
        table.setAccessibilityIdentifier("theme-list")
        table.dataSource = self
        table.delegate = self
        table.reloadData()

        view.documentView = table
        view.drawsBackground = false
        view.hasVerticalScroller = true
        view.autohidesScrollers = true
        view.translatesAutoresizingMaskIntoConstraints = false
        // A scroll view has no size of its own, and the window is measured
        // once: the height has a floor that does not depend on how many
        // files the user has. The column beside the showcase gives the
        // height itself, and more rows scroll.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: table.rect(ofRow: Self.minimumRows - 1).maxY),
        ])
    }

    /// Selects the row of the theme with that id, and brings it into view.
    /// A file that was changed keeps its id and not its colours.
    func select(_ theme: ThemeCatalog.Entry) {
        guard let row = themes.firstIndex(where: { $0.id == theme.id }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        revealSelection()
    }

    /// Scrolls no more than the selected row needs. A list with no size yet
    /// has nothing in view, and would put the row at its top and hide the
    /// rows above it: so that is done after the window laid the list out.
    private func revealSelection() {
        guard view.contentView.bounds.height > 0 else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                view.layoutSubtreeIfNeeded()
                if view.contentView.bounds.height > 0 { table.scrollRowToVisible(table.selectedRow) }
            }
            return
        }
        table.scrollRowToVisible(table.selectedRow)
    }

    /// Draws each row again with the marks it has now. With the same themes
    /// the selection stays; with others the caller selects a row again.
    func show(_ themes: [ThemeCatalog.Entry], marks: (ThemeCatalog.Entry) -> [ThemeVariant]) {
        let sameRows = themes == self.themes
        self.themes = themes
        self.marks = themes.map(marks)
        if sameRows {
            table.reloadData(forRowIndexes: IndexSet(themes.indices), columnIndexes: [0])
        } else {
            table.reloadData()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        themes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        Row(themes[row], marks: marks[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard themes.indices.contains(table.selectedRow) else { return }
        onSelect?(themes[table.selectedRow])
    }

    /// The views are the cell's own subviews: a cell tells only those of a
    /// selected row to draw for its highlight.
    private final class Row: NSTableCellView {
        init(_ theme: ThemeCatalog.Entry, marks: [ThemeVariant]) {
            super.init(frame: .zero)
            let swatch = NSImageView(image: ThemePicture.swatch(theme.palette))
            swatch.setAccessibilityElement(false)
            let title = NSTextField(labelWithString: theme.title)
            title.setContentHuggingPriority(.init(1), for: .horizontal)
            // A file's name can be long: the title gives way, the marks stay.
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            // What tells two rows with one title apart, for a QA script. A
            // cell view gives the Accessibility API no identifier of its own.
            title.setAccessibilityIdentifier(theme.id)
            textField = title

            let views = [swatch, title] + marks.map { Mark($0) }
            for (index, view) in views.enumerated() {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
                view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
                let before = index == 0 ? leadingAnchor : views[index - 1].trailingAnchor
                view.leadingAnchor.constraint(equalTo: before, constant: index == 0 ? 2 : index == 1 ? 8 : 6)
                    .isActive = true
            }
            views[views.count - 1].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    /// The appearance's name in a ring of the text's colour.
    private final class Mark: NSTextField {
        private static let padding: CGFloat = 3

        convenience init(_ variant: ThemeVariant) {
            self.init(labelWithString: variant.title)
            font = .systemFont(ofSize: 9.5)
            alignment = .center
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        override var intrinsicContentSize: NSSize {
            let text = super.intrinsicContentSize
            return NSSize(width: text.width + 2 * Self.padding, height: text.height)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2
            )
            let selected = cell?.backgroundStyle == .emphasized
            (selected ? NSColor.alternateSelectedControlTextColor : .labelColor).setStroke()
            ring.stroke()
        }
    }
}
