import AppKit
import TarmacKit

/// The sidebar of the Settings window (spec 2610.0007): the panes as a
/// source list, in the order of `SettingsPane.allCases`. It reports the pane
/// that was selected; what a pane shows is not its concern.
@MainActor
final class SettingsSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let panes = SettingsPane.allCases
    private let table = NSTableView()
    var onSelect: ((SettingsPane) -> Void)?

    override func loadView() {
        table.style = .sourceList
        table.headerView = nil
        table.allowsEmptySelection = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        view = scroll
    }

    func select(_ pane: SettingsPane) {
        guard let row = panes.firstIndex(of: pane) else { return }
        // The table has no rows until the view is loaded.
        _ = view
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        panes.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.symbol(of: panes[row]), accessibilityDescription: nil)
        let label = NSTextField(labelWithString: panes[row].title)
        let cell = NSTableCellView()
        cell.imageView = icon
        cell.textField = label
        for view in [icon, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard panes.indices.contains(table.selectedRow) else { return }
        onSelect?(panes[table.selectedRow])
    }

    private static func symbol(of pane: SettingsPane) -> String {
        switch pane {
        case .fonts: "textformat"
        case .theme: "circle.lefthalf.filled"
        }
    }
}
