import AppKit
import TarmacKit

/// The Fonts pane of the Settings window (specs 2610.0005, 2610.0006): one
/// row for each font role, a list of the Mac's families, a size for the
/// roles that have one, and a sample line in the face in effect. What a row
/// lists and selects is `FontMenu`'s decision and which size a text means is
/// `FontSizeRule`'s; this builds the controls and forwards a choice to
/// `FontSettings`.
@MainActor
final class FontsPane: NSObject {
    private static let sampleText = "The quick brown fox 0123456789"
    private static let nerdFontNote = "Prompt and Powerline icons need a Nerd Font."
    private static let controlWidth: CGFloat = 280
    private static let sizeFieldWidth: CGFloat = 48

    @MainActor
    private final class Row {
        let role: FontRole
        let popup = NSPopUpButton()
        let sample = NSTextField(labelWithString: FontsPane.sampleText)
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
    private(set) lazy var view = makeView()

    init(fonts: FontSettings) {
        self.fonts = fonts
    }

    /// The families are read each time the window opens: a font installed
    /// since the last time is in the lists.
    func reload() {
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

    private func makeView() -> NSView {
        let rowControls = rows.map { controls(for: $0) }
        let box = SettingsGroup.box(zip(rows, rowControls).map { ($0.role.title, $1, .firstBaseline) })
        // One width for the three: a row with no size keeps its pop-up under
        // the others'.
        NSLayoutConstraint.activate(rowControls.dropFirst().map {
            $0.widthAnchor.constraint(equalTo: rowControls[0].widthAnchor)
        })
        return box
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
        guard let size = row.sizeControls else { return row.popup }
        size.field.target = self
        size.field.action = #selector(typeSize(_:))
        size.field.setAccessibilityLabel("\(row.role.title) font size")
        size.field.widthAnchor.constraint(equalToConstant: Self.sizeFieldWidth).isActive = true
        size.stepper.target = self
        size.stepper.action = #selector(step(_:))
        let line = NSStackView(views: [row.popup, size.field, size.stepper])
        line.spacing = 6
        return line
    }
}
