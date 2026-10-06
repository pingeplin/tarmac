import AppKit
import TarmacKit

/// The list of the Theme pane (spec 2610.0008): a row for each theme of the
/// catalogue, in its order, with a swatch, the title and a mark for each
/// appearance the theme is chosen for. It reports the row that was selected;
/// what a selected theme does is not its concern.
@MainActor
final class ThemeList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let width: CGFloat = 260

    private let themes = ThemeCatalog.all
    private let table = NSTableView()
    private var marks: [[ThemeVariant]]
    let view = NSScrollView()
    var onSelect: ((ThemeCatalog.Entry) -> Void)?

    override init() {
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
        view.translatesAutoresizingMaskIntoConstraints = false
        // A scroll view has no size of its own, and the window is measured
        // once: every row is in view with no scrolling.
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: table.rect(ofRow: themes.count - 1).maxY),
        ])
    }

    func select(_ theme: ThemeCatalog.Entry) {
        guard let row = themes.firstIndex(of: theme) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Draws each row again with the marks it has now. The selection stays.
    func show(marks: (ThemeCatalog.Entry) -> [ThemeVariant]) {
        self.marks = themes.map(marks)
        table.reloadData(forRowIndexes: IndexSet(themes.indices), columnIndexes: [0])
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
