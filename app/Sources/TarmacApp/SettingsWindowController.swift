import AppKit
import TarmacKit

/// The Settings window (spec 2610.0005): one row for each font role, a list
/// of the Mac's families and a sample line in the face in effect. What a row
/// lists and selects is `FontMenu`'s decision; this builds the controls and
/// forwards a choice to `FontSettings`.
@MainActor
final class SettingsWindowController: NSObject {
    static let showAction = #selector(show(_:))

    private static let sampleText = "The quick brown fox 0123456789"
    private static let nerdFontNote = "Prompt and Powerline icons need a Nerd Font."
    private static let controlWidth: CGFloat = 280
    private static let margin: CGFloat = 20

    @MainActor
    private final class Row {
        let popup = NSPopUpButton()
        let sample = NSTextField(labelWithString: SettingsWindowController.sampleText)
        var menu = FontMenu(role: .terminal, installed: [], saved: nil)
    }

    private let fonts: FontSettings
    private let rows = Dictionary(uniqueKeysWithValues: FontRole.allCases.map { ($0, Row()) })
    private lazy var window = makeWindow()

    init(fonts: FontSettings) {
        self.fonts = fonts
    }

    /// The families are read each time the window opens: a font installed
    /// since the last time is in the lists.
    @objc func show(_ sender: Any?) {
        if !window.isVisible { reload() }
        window.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        let installed = InstalledFonts.all()
        for (role, row) in rows {
            row.menu = FontMenu(role: role, installed: installed, saved: fonts.saved(role))
            row.popup.removeAllItems()
            row.popup.addItems(withTitles: row.menu.titles)
            row.popup.selectItem(at: row.menu.selected)
        }
        showSamples()
    }

    private func showSamples() {
        for (role, row) in rows {
            row.sample.font = Theme.sample(role, size: NSFont.systemFontSize)
        }
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        guard let (role, row) = rows.first(where: { $0.value.popup === sender }) else { return }
        fonts.choose(row.menu.choice(at: sender.indexOfSelectedItem), for: role)
        showSamples()
    }

    private func makeWindow() -> NSWindow {
        let grid = NSGridView(views: FontRole.allCases.map { role in
            let label = NSTextField(labelWithString: role.title + ":")
            return [label, controls(for: role)]
        })
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 16
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.margin),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
        ])

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        return window
    }

    /// A role's pop-up over its sample line, and under the terminal's the one
    /// thing the system fonts cannot do.
    private func controls(for role: FontRole) -> NSView {
        guard let row = rows[role] else { return NSView() }
        row.popup.target = self
        row.popup.action = #selector(choose(_:))
        row.sample.textColor = .secondaryLabelColor
        row.sample.lineBreakMode = .byTruncatingTail

        var lines: [NSView] = [row.popup, row.sample]
        if role == .terminal {
            let note = NSTextField(labelWithString: Self.nerdFontNote)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .tertiaryLabelColor
            lines.append(note)
        }
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        NSLayoutConstraint.activate([
            row.popup.widthAnchor.constraint(equalToConstant: Self.controlWidth),
            row.sample.widthAnchor.constraint(equalToConstant: Self.controlWidth),
        ])
        return stack
    }
}
