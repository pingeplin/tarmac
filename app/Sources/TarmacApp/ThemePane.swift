import AppKit
import TarmacKit

/// The Theme pane of the Settings window (specs 2610.0007, 2610.0008): the
/// row *Appearance*, with a tile for each `ThemeChoice`, and under it the
/// list of the themes beside a showcase of the one that is selected there.
/// A selected row shows a theme and changes nothing else; the showcase's two
/// boxes choose the shown theme for an appearance.
///
/// What a box is and gives, a row's marks and the words are `ThemeBrowser`'s
/// decisions. A pressed tile and a changed box are forwarded to
/// `ThemeSettings`, and what shows is what it holds.
@MainActor
final class ThemePane: NSObject {
    private let theme: ThemeSettings
    private let tiles = ThemeChoice.allCases.map { ThemeTile.button($0) }
    private let list = ThemeList()
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    private let boxes = ThemeVariant.allCases.map {
        NSButton(checkboxWithTitle: ThemeBrowser.boxTitle(for: $0), target: nil, action: nil)
    }
    private let note = NSTextField(labelWithString: "")
    /// The theme in the showcase. It is the pane's own: nothing saves it,
    /// and only a selected row and the window's opening change it.
    private var shown: ThemeCatalog.Entry
    private(set) lazy var view = makeView()

    init(theme: ThemeSettings) {
        self.theme = theme
        shown = theme.inEffect
    }

    /// The window opens: the showcase has the theme in effect.
    func reload() {
        list.select(theme.inEffect)
        show(theme.inEffect)
        showChosen()
    }

    private func show(_ entry: ThemeCatalog.Entry) {
        shown = entry
        title.stringValue = entry.title
        caption.stringValue = ThemeBrowser.caption(of: entry)
        picture.image = ThemePicture.showcase(entry.palette)
        note.stringValue = ThemeBrowser.contrastNote(entry.palette)
        showBoxes()
    }

    private func showBoxes() {
        for (variant, box) in zip(ThemeVariant.allCases, boxes) {
            let state = ThemeBrowser.box(shown: shown, chosen: theme.theme(for: variant), for: variant)
            box.state = state.isOn ? .on : .off
            box.isEnabled = state.isEnabled
        }
    }

    /// The tiles and the marks: what is chosen, whatever theme is shown.
    private func showChosen() {
        for (choice, tile) in zip(ThemeChoice.allCases, tiles) {
            ThemeTile.picture(choice, on: tile) { theme.theme(for: $0).palette }
            tile.state = choice == theme.choice ? .on : .off
        }
        list.show { ThemeBrowser.marks(of: $0, themes: theme.themes) }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        theme.choose(ThemeChoice.allCases[index])
        showChosen()
    }

    @objc private func apply(_ sender: NSButton) {
        guard let index = boxes.firstIndex(of: sender) else { return }
        let variant = ThemeVariant.allCases[index]
        theme.choose(ThemeBrowser.toggled(shown: shown, on: sender.state == .on, for: variant), for: variant)
        showChosen()
        showBoxes()
    }

    private func makeView() -> NSView {
        // The window takes its one size from the panes as they are made: a
        // tile or a showcase with no picture yet would be measured short.
        reload()
        list.onSelect = { [weak self] in self?.show($0) }
        for tile in tiles {
            tile.target = self
            tile.action = #selector(choose(_:))
        }
        for box in boxes {
            box.target = self
            box.action = #selector(apply(_:))
        }
        let row = NSStackView(views: tiles)
        row.spacing = 8
        let groups = [SettingsGroup.box([("Appearance", row, .none)]), browser()]
        let pane = NSStackView(views: groups)
        pane.orientation = .vertical
        pane.spacing = 10
        NSLayoutConstraint.activate(groups.flatMap {
            [
                $0.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            ]
        })
        return pane
    }

    /// The list, and beside it the showcase.
    private func browser() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        let columns = NSStackView(views: [list.view, rule, showcase()])
        columns.spacing = 0
        columns.alignment = .top
        NSLayoutConstraint.activate([list.view, rule].flatMap {
            [
                $0.topAnchor.constraint(equalTo: columns.topAnchor),
                $0.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            ]
        })
        return SettingsGroup.box(holding: columns, margins: .zero)
    }

    /// The identifiers are for a QA script: the window has many texts, and
    /// each row of the list has a picture too.
    private func showcase() -> NSView {
        title.font = .boldSystemFont(ofSize: 14)
        title.setAccessibilityIdentifier("theme-showcase-title")
        for label in [caption, note] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
        }
        caption.setAccessibilityIdentifier("theme-showcase-caption")
        picture.setAccessibilityElement(true)
        picture.setAccessibilityRole(.image)
        picture.setAccessibilityLabel("Preview")
        picture.setAccessibilityIdentifier("theme-showcase-picture")
        note.setAccessibilityIdentifier("theme-contrast-note")

        let heading = NSStackView(views: [title, caption])
        heading.alignment = .firstBaseline
        let apply = NSStackView(views: boxes)
        apply.spacing = 18
        let column = NSStackView(views: [heading, picture, apply, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        // Measured: a vertical stack view keeps its right inset beside every
        // view but its widest.
        column.widthAnchor.constraint(greaterThanOrEqualTo: picture.widthAnchor, constant: 24).isActive = true
        return column
    }
}
