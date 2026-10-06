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
    /// Runs `tell` on every view under this one, then on this one: a view
    /// that measures its subviews finds them already changed. A culled card
    /// is hidden but still in the tree, so it is told too.
    func tellTree(_ tell: (NSView) -> Void) {
        subviews.forEach { $0.tellTree(tell) }
        tell(self)
    }

    func broadcastFontsChanged() {
        tellTree { ($0 as? FontFollowing)?.fontsChanged() }
    }
}

extension TerminalView: FontFollowing {
    func fontsChanged() {
        fontFamily = Theme.fontFamilies[.terminal]
        fontSize = Theme.terminalFontSize
    }
}
