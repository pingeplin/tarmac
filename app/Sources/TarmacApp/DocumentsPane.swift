import AppKit
import TarmacKit

/// The Documents pane of the Settings window (spec 2611.0025): the group
/// *Markdown cards*, with a tile for each side of the sidebar. A pressed tile
/// is forwarded to `DocumentSettings`, and what shows is what it holds.
@MainActor
final class DocumentsPane: NSObject {
    private let documents: DocumentSettings
    private let tiles = DocSidebar.Side.allCases.map { DocSideTile.button($0) }
    private(set) lazy var view = makeView()

    init(documents: DocumentSettings) {
        self.documents = documents
    }

    /// The pictures follow the theme in effect, so they are drawn again each
    /// time the pane shows.
    func reload() {
        for (side, tile) in zip(DocSidebar.Side.allCases, tiles) {
            DocSideTile.picture(side, on: tile, palette: Theme.palette)
        }
        showChosen()
    }

    private func showChosen() {
        for (side, tile) in zip(DocSidebar.Side.allCases, tiles) {
            tile.state = side == documents.side ? .on : .off
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        documents.choose(DocSidebar.Side.allCases[index])
        showChosen()
    }

    private func makeView() -> NSView {
        // The window takes its one size from the panes as they are made.
        reload()
        for tile in tiles {
            tile.target = self
            tile.action = #selector(choose(_:))
        }
        let row = NSStackView(views: tiles)
        row.spacing = 8
        let help = NSTextField(labelWithString: "The sidebar holds the front matter and the outline.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        let control = NSStackView(views: [row, help])
        control.orientation = .vertical
        control.alignment = .leading
        control.spacing = 6
        return SettingsGroup.titled("Markdown cards", SettingsGroup.box(holding: labelled("Sidebar side", control)))
    }

    /// Unlike the shared rows, whose control sits at the trailing edge, the
    /// tiles start after a fixed label column, as the approved mockup draws
    /// them (#456).
    private func labelled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let grid = NSGridView(views: [[label, control]])
        grid.column(at: 0).width = 150
        grid.columnSpacing = 16
        grid.yPlacement = .top
        let cell = grid.cell(for: label)
        cell?.yPlacement = .none
        cell?.customPlacementConstraints = [label.topAnchor.constraint(equalTo: control.topAnchor, constant: 4)]
        return grid
    }
}
