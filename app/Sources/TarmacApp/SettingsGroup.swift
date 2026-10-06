import AppKit

/// A grouped box of the Settings window: each row a label on the left and
/// its control on the right, with a rule between two rows, as macOS System
/// Settings draws a group.
@MainActor
enum SettingsGroup {
    /// `alignment` is how the label meets the control: `.none` puts the two
    /// at the row's top.
    typealias Row = (title: String, control: NSView, alignment: NSGridRow.Alignment)

    private static let padding = NSSize(width: 12, height: 10)

    static func box(_ rows: [Row]) -> NSBox {
        let grid = NSGridView()
        for (index, row) in rows.enumerated() {
            if index > 0 { addRule(to: grid) }
            grid.addRow(with: [NSTextField(labelWithString: row.title), row.control]).rowAlignment = row.alignment
        }
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.yPlacement = .top
        grid.rowSpacing = padding.height
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false

        let box = NSBox()
        box.titlePosition = .noTitle
        box.contentViewMargins = padding
        box.translatesAutoresizingMaskIntoConstraints = false
        guard let content = box.contentView else { return box }
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        return box
    }

    private static func addRule(to grid: NSGridView) {
        let rule = NSBox()
        rule.boxType = .separator
        let row = grid.addRow(with: [rule])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.cell(at: 0).xPlacement = .fill
    }
}
