import AppKit
import TarmacTerm

/// A view that draws with a chosen font (`Theme.fontFamilies`,
/// `Theme.fontSizes`) and holds on to it: it takes the font again when the
/// choice changes.
@MainActor
protocol FontFollowing: NSView {
    func fontsChanged()
}

extension NSView {
    /// Tells every view under this one, then this one: a view that measures
    /// its subviews finds them already in the new font. A culled card is
    /// hidden but still in the tree, so it is told too.
    func broadcastFontsChanged() {
        subviews.forEach { $0.broadcastFontsChanged() }
        (self as? FontFollowing)?.fontsChanged()
    }
}

extension TerminalView: FontFollowing {
    func fontsChanged() {
        fontFamily = Theme.fontFamilies[.terminal]
        fontSize = Theme.terminalFontSize
    }
}
