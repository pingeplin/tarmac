import AppKit
import TarmacTerm

/// A view that draws with a chosen font (`Theme.fontFamilies`) and holds on to
/// it: it takes the font again when the choice changes.
@MainActor
protocol FontFollowing: NSView {
    func fontsChanged()
}

extension NSView {
    /// Tells this view and every view under it. A culled card is hidden but
    /// still in the tree, so it is told too.
    func broadcastFontsChanged() {
        (self as? FontFollowing)?.fontsChanged()
        subviews.forEach { $0.broadcastFontsChanged() }
    }
}

extension TerminalView: FontFollowing {
    func fontsChanged() {
        fontFamily = Theme.fontFamilies[.terminal]
    }
}
