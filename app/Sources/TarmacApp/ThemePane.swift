import AppKit
import TarmacKit

/// The Theme pane of the Settings window (spec 2610.0007): one row,
/// *Appearance*, with a tile for each `ThemeChoice`. A pressed tile is
/// forwarded to `ThemeSettings`, and the selected tile is the choice it
/// holds.
@MainActor
final class ThemePane: NSObject {
    private let theme: ThemeSettings
    private let tiles = ThemeChoice.allCases.map { ThemeTile.button($0) }
    private(set) lazy var view = makeView()

    init(theme: ThemeSettings) {
        self.theme = theme
    }

    func reload() {
        for (choice, tile) in zip(ThemeChoice.allCases, tiles) { tile.state = choice == theme.choice ? .on : .off }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        theme.choose(ThemeChoice.allCases[index])
        reload()
    }

    private func makeView() -> NSView {
        for tile in tiles {
            tile.target = self
            tile.action = #selector(choose(_:))
        }
        let row = NSStackView(views: tiles)
        row.spacing = 8
        return SettingsGroup.box([("Appearance", row, .none)])
    }
}
