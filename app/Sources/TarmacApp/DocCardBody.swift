import AppKit
import TarmacKit

/// The body of a doc card: a markdown doc or an HTML card, by the doc's path.
@MainActor
protocol DocCardBody: NSView {
    /// Shows the doc as it is on disk now. `lastChangedMs` is its change time
    /// as the daemon last reported it.
    func refresh(lastChangedMs: UInt64?)

    func setBoardZoom(_ zoom: CGFloat)

    /// Where the doc is scrolled to, or nil once what it reported is gone: a
    /// reload, a web process that terminated.
    var onScrollChanged: ((ScrollMetrics?) -> Void)? { get set }

    /// The height, in the body's own units, that an overlay of its own hides
    /// at its bottom; the scroll thumb's track ends above it.
    var scrollCover: CGFloat { get }
    var onScrollCoverChanged: (() -> Void)? { get set }
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
