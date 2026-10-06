import AppKit
import TarmacKit
import TarmacTerm

/// A view that keeps a colour of the theme (`Theme.palette`): a layer's
/// colour is a copy, and so is a text's. It takes its colours again when the
/// theme in effect changes, for the state it is in at that moment.
@MainActor
protocol ThemeFollowing: NSView {
    func themeChanged()
}

extension NSView {
    func broadcastThemeChanged() {
        tellTree { ($0 as? ThemeFollowing)?.themeChanged() }
    }
}

extension TerminalTheme {
    init(_ colors: Palette.Terminal) {
        self.init(
            foreground: RGB(hex: colors.foreground), background: RGB(hex: colors.background),
            cursor: RGB(hex: colors.cursor), selection: RGB(hex: colors.selection),
            selectionAlpha: colors.selectionAlpha, ansi: colors.ansi.map(RGB.init(hex:))
        )
    }
}

extension TerminalView: ThemeFollowing {
    func themeChanged() {
        theme = TerminalTheme(Theme.palette.terminal)
    }
}
