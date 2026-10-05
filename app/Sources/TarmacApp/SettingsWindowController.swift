import AppKit
import TarmacKit

/// The Settings window (specs 2610.0005, 2610.0006): one row for each font
/// role, a list of the Mac's families, a size for the roles that have one,
/// and a sample line in the face in effect. What a row lists and selects is
/// `FontMenu`'s decision and which size a text means is `FontSizeRule`'s; this
/// builds the controls and forwards a choice to `FontSettings`.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let showAction = #selector(show(_:))

    private static let sampleText = "The quick brown fox 0123456789"
    private static let nerdFontNote = "Prompt and Powerline icons need a Nerd Font."
    private static let controlWidth: CGFloat = 280
    private static let sizeFieldWidth: CGFloat = 48
    private static let margin: CGFloat = 20

    @MainActor
    private final class Row {
        let role: FontRole
        let popup = NSPopUpButton()
        let sample = NSTextField(labelWithString: SettingsWindowController.sampleText)
        let sizeControls: SizeControls?
        var menu: FontMenu

        init(_ role: FontRole) {
            self.role = role
            sizeControls = role.sizeRule.map(SizeControls.init)
            menu = FontMenu(role: role, installed: [], saved: nil)
        }

        func showSample() {
            sample.font = Theme.sample(role)
        }
    }

    /// A size as a text and as a stepper, which show one number.
    @MainActor
    private final class SizeControls {
        let field = NSTextField(string: "")
        let stepper = NSStepper()

        init(_ rule: FontSizeRule) {
            field.alignment = .right
            stepper.minValue = rule.range.lowerBound
            stepper.maxValue = rule.range.upperBound
            stepper.increment = FontSizeRule.step
            // An `NSStepper` wraps by default: a step up at the top end would
            // give the bottom one.
            stepper.valueWraps = false
        }

        /// Also drops a text that is being typed: a step is made from the
        /// size in effect.
        func show(_ size: Double) {
            field.stringValue = FontSizeRule.text(size)
            stepper.doubleValue = size
        }
    }

    private let fonts: FontSettings
    private let rows = FontRole.allCases.map { Row($0) }
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
        for row in rows {
            row.menu = FontMenu(role: row.role, installed: installed, saved: fonts.saved[row.role])
            row.popup.removeAllItems()
            row.popup.addItems(withTitles: row.menu.titles)
            row.popup.selectItem(at: row.menu.selected)
            row.showSample()
            showSize(of: row)
        }
    }

    private func showSize(of row: Row) {
        guard let size = fonts.size(for: row.role) else { return }
        row.sizeControls?.show(size)
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        guard let row = rows.first(where: { $0.popup === sender }) else { return }
        fonts.choose(row.menu.choice(at: sender.indexOfSelectedItem), for: row.role)
        row.showSample()
    }

    @objc private func step(_ sender: NSStepper) {
        guard let row = rows.first(where: { $0.sizeControls?.stepper === sender }) else { return }
        fonts.chooseSize(sender.doubleValue, for: row.role)
        showSize(of: row)
    }

    /// Text that is no size puts the field back; so does a size already in
    /// effect, typed another way (`13.50`).
    @objc private func typeSize(_ sender: NSTextField) {
        guard let row = rows.first(where: { $0.sizeControls?.field === sender }) else { return }
        if let typed = row.role.sizeRule?.typed(sender.stringValue) { fonts.chooseSize(typed, for: row.role) }
        showSize(of: row)
    }

    /// AppKit does not end a field's editing when its window closes: the
    /// typed text would be lost, and still be there when the window opens.
    func windowWillClose(_ notification: Notification) {
        window.makeFirstResponder(nil)
    }

    private func makeWindow() -> NSWindow {
        let grid = NSGridView(views: rows.map { row in
            [NSTextField(labelWithString: row.role.title + ":"), controls(for: row)]
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
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = content
        window.center()
        return window
    }

    /// A row's pop-up, with its size beside it, over its sample line, and
    /// under the terminal's the one thing the system fonts cannot do.
    private func controls(for row: Row) -> NSView {
        row.popup.target = self
        row.popup.action = #selector(choose(_:))
        row.sample.textColor = .secondaryLabelColor
        row.sample.lineBreakMode = .byTruncatingTail

        var lines: [NSView] = [choices(for: row), row.sample]
        if row.role == .terminal {
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

    private func choices(for row: Row) -> NSView {
        guard let controls = row.sizeControls else { return row.popup }
        controls.field.target = self
        controls.field.action = #selector(typeSize(_:))
        controls.field.setAccessibilityLabel("\(row.role.title) font size")
        controls.field.widthAnchor.constraint(equalToConstant: Self.sizeFieldWidth).isActive = true
        controls.stepper.target = self
        controls.stepper.action = #selector(step(_:))
        let line = NSStackView(views: [row.popup, controls.field, controls.stepper])
        line.spacing = 6
        return line
    }
}
