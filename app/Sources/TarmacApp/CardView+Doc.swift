import AppKit
import TarmacKit

extension CardView {
    /// The body of a markdown doc card; nil on every other card.
    var markdownBody: DocWebView? { docBody as? DocWebView }

    /// Where a press on `hit`, a view of this card, lands (`CardPress`).
    func pressPlace(of hit: NSView) -> CardPress.Place {
        if hit is HeaderButton { return .headerControl }
        if markdownBody?.pointerIsOverLink == true, bodyContains(hit) { return .link }
        return .elsewhere
    }
}
