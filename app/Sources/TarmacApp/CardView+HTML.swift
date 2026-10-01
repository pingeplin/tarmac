import AppKit
import TarmacKit

extension CardView {
    /// The body of an HTML card; nil on every other card.
    var htmlBody: HTMLCardView? { docBody as? HTMLCardView }

    /// Shows the console badge in the header once an HTML card's document has
    /// logged something. Pressing it opens and closes the console.
    func wireHTMLBody() {
        guard let html = htmlBody else { return }
        var badge: HeaderButton?
        html.onConsoleChanged = { [weak self, weak html] count in
            guard let self, let label = CardConsole.badgeLabel(count: count) else { return }
            if let badge {
                badge.setGlyph(label)
                return
            }
            let button = HeaderButton(glyph: label, toolTip: "Toggle console", fontSize: 9.5)
            button.onClick = { html?.toggleConsole() }
            badge = button
            self.header.setAccessory(button)
            self.contentAdded()
        }
    }
}
