import AppKit
import TarmacKit

/// The body of a doc card: a markdown doc or an HTML card, by the doc's path.
@MainActor
protocol DocCardBody: NSView {
    /// Shows the doc as it is on disk now. `lastChangedMs` is its change time
    /// as the daemon last reported it.
    func refresh(lastChangedMs: UInt64?)

    func setBoardZoom(_ zoom: CGFloat)
}

@MainActor
enum DocCardBodies {
    static func make(path: String) -> any DocCardBody {
        switch DocKind(path: path) {
        case .markdown: return DocWebView(path: path)
        case .html: return HTMLCardView(path: path)
        }
    }
}
