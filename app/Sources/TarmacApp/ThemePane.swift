import AppKit
import TarmacKit

/// The Theme pane of the Settings window (specs 2610.0007, 2610.0008): the
/// row *Appearance*, with a tile for each `ThemeChoice`, and under it a row
/// for each appearance, with a pop-up of the themes it is offered. A pressed
/// tile and a chosen theme are forwarded to `ThemeSettings`, and what shows
/// is what it holds.
@MainActor
final class ThemePane: NSObject {
    private let theme: ThemeSettings
    private let tiles = ThemeChoice.allCases.map { ThemeTile.button($0) }
    private let popups = ThemeVariant.allCases.map { variant in
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ThemeCatalog.offered(for: variant).map(\.title))
        return popup
    }
    private(set) lazy var view = makeView()

    init(theme: ThemeSettings) {
        self.theme = theme
    }

    func reload() {
        for (choice, tile) in zip(ThemeChoice.allCases, tiles) {
            ThemeTile.picture(choice, on: tile) { [theme] in theme.theme(for: $0).palette }
            tile.state = choice == theme.choice ? .on : .off
        }
        for (variant, popup) in zip(ThemeVariant.allCases, popups) {
            popup.selectItem(withTitle: theme.theme(for: variant).title)
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        theme.choose(ThemeChoice.allCases[index])
        reload()
    }

    @objc private func chooseTheme(_ sender: NSPopUpButton) {
        guard let index = popups.firstIndex(of: sender) else { return }
        let variant = ThemeVariant.allCases[index]
        theme.choose(ThemeCatalog.offered(for: variant)[sender.indexOfSelectedItem], for: variant)
        reload()
    }

    private func makeView() -> NSView {
        // The window takes its one size from the panes as they are made: a
        // tile with no picture yet would be measured short.
        reload()
        for tile in tiles {
            tile.target = self
            tile.action = #selector(choose(_:))
        }
        for popup in popups {
            popup.target = self
            popup.action = #selector(chooseTheme(_:))
        }
        let row = NSStackView(views: tiles)
        row.spacing = 8
        let box = SettingsGroup.box(
            [("Appearance", row, .none)]
                + zip(ThemeVariant.allCases, popups).map { ($0.rowTitle, $1, .firstBaseline) }
        )
        // Each pop-up is as wide as its longest title: one width for the two.
        for popup in popups.dropFirst() {
            popup.widthAnchor.constraint(equalTo: popups[0].widthAnchor).isActive = true
        }
        return box
    }
}
