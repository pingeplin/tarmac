import AppKit
import TarmacKit

/// The Theme pane of the Settings window (specs 2610.0007, 2610.0008,
/// 2610.0009): the row *Appearance*, with a tile for each `ThemeChoice`,
/// under it the list of the themes beside a showcase of the one that is
/// selected there, and under that a line about the user's theme files. A
/// selected row shows a theme and changes nothing else; the showcase's two
/// boxes choose the shown theme for an appearance.
///
/// What a box is and gives, a row's marks, the shown theme after the themes
/// changed and the words are `ThemeBrowser`'s decisions. A pressed tile and a
/// changed box are forwarded to `ThemeSettings`, and what shows is what it
/// holds.
@MainActor
final class ThemePane: NSObject {
    private let theme: ThemeSettings
    private let tiles = ThemeChoice.allCases.map { ThemeTile.button($0) }
    private let list: ThemeList
    private let title = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let picture = NSImageView()
    private let boxes = ThemeVariant.allCases.map {
        NSButton(checkboxWithTitle: ThemeBrowser.boxTitle(for: $0), target: nil, action: nil)
    }
    private let note = NSTextField(wrappingLabelWithString: "")
    private let filesNote = NSTextField(labelWithString: "")
    private let openFolder = NSButton(title: "Open Themes Folder", target: nil, action: nil)
    /// The theme in the showcase. It is the pane's own: nothing saves it. A
    /// selected row and the window's opening change it, and a change of the
    /// themes gives it the colours its id has then (`ThemeBrowser.shown`).
    private var shown: ThemeCatalog.Entry
    private(set) lazy var view = makeView()

    init(theme: ThemeSettings) {
        self.theme = theme
        list = ThemeList(themes: theme.library.all)
        shown = theme.inEffect
        super.init()
        theme.onThemesChange = { [weak self] in self?.themesChanged() }
    }

    /// The window opens: the showcase has the theme in effect.
    func reload() {
        present(theme.inEffect)
    }

    /// A theme file was added, changed or removed.
    private func themesChanged() {
        present(ThemeBrowser.shown(shown, in: theme.library, inEffect: theme.inEffect))
    }

    /// `entry` is found before the list takes its rows: a list that lost
    /// its selected row reports another one, which would be shown.
    private func present(_ entry: ThemeCatalog.Entry) {
        showChosen()
        list.select(entry)
        show(entry)
    }

    private func show(_ entry: ThemeCatalog.Entry) {
        shown = entry
        title.stringValue = entry.title
        caption.stringValue = ThemeBrowser.caption(of: entry)
        picture.image = ThemePicture.showcase(entry.palette)
        note.stringValue = ThemeBrowser.contrastNote(entry.palette)
        note.toolTip = ThemeBrowser.toolTip(ThemeBrowser.contrastDetail(entry.palette))
        showBoxes()
    }

    private func showBoxes() {
        for (variant, box) in zip(ThemeVariant.allCases, boxes) {
            let state = ThemeBrowser.box(shown: shown, chosen: theme.theme(for: variant), for: variant)
            box.state = state.isOn ? .on : .off
            box.isEnabled = state.isEnabled
        }
    }

    /// The tiles, the rows and their marks, and the line about the files:
    /// what there is and what is chosen, whatever theme is shown.
    private func showChosen() {
        for (choice, tile) in zip(ThemeChoice.allCases, tiles) {
            ThemeTile.picture(choice, on: tile) { theme.theme(for: $0).palette }
            tile.state = choice == theme.choice ? .on : .off
        }
        let library = theme.library
        let chosen = Dictionary(uniqueKeysWithValues: ThemeVariant.allCases.map { ($0, theme.theme(for: $0)) })
        list.show(library.all) { entry in
            ThemeBrowser.marks(of: entry) { chosen[$0] ?? theme.theme(for: $0) }
        }
        filesNote.stringValue = ThemeBrowser.filesNote(
            themes: library.fileThemes.count, refused: library.refused.count
        )
        filesNote.toolTip = ThemeBrowser.toolTip(library.refused.map(\.detail))
    }

    @objc private func choose(_ sender: NSButton) {
        guard let index = tiles.firstIndex(of: sender) else { return }
        theme.choose(ThemeChoice.allCases[index])
        showChosen()
    }

    /// The launch makes no folder: this is where it is made.
    @objc private func openFolder(_ sender: NSButton) {
        do {
            try FileManager.default.createDirectory(atPath: theme.folder, withIntermediateDirectories: true)
        } catch {
            Log.stderr("could not make the themes folder: \(error)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: theme.folder, isDirectory: true))
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
        openFolder.target = self
        openFolder.action = #selector(openFolder(_:))
        let row = NSStackView(views: tiles)
        row.spacing = 8
        let groups = [SettingsGroup.box([("Appearance", row, .none)]), browser(), files()]
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

    /// The line about the user's theme files, and the way to their folder.
    private func files() -> NSView {
        filesNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filesNote.textColor = .secondaryLabelColor
        filesNote.lineBreakMode = .byTruncatingTail
        filesNote.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        filesNote.setContentHuggingPriority(.init(1), for: .horizontal)
        filesNote.setAccessibilityIdentifier("theme-files-note")
        openFolder.controlSize = .small
        let row = NSStackView(views: [filesNote, openFolder])
        row.alignment = .firstBaseline
        return row
    }

    /// The identifiers are for a QA script: the window has many texts, and
    /// each row of the list has a picture too.
    private func showcase() -> NSView {
        title.font = .boldSystemFont(ofSize: 14)
        // A file's name can be long, and the window has one size: the title
        // gives way, and the caption stays whole.
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
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
        // The note can have two sentences, and the window has one size: it
        // wraps in the picture's width, and has the room of two lines at
        // all times.
        note.maximumNumberOfLines = 2
        let noteHeight = 2 * ceil(NSLayoutManager().defaultLineHeight(for: note.font ?? .systemFont(ofSize: 0)))
        NSLayoutConstraint.activate([
            note.widthAnchor.constraint(equalTo: picture.widthAnchor),
            note.heightAnchor.constraint(equalToConstant: noteHeight),
        ])
        return column
    }
}
