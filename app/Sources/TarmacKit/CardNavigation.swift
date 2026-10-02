/// Where a card's web view may navigate. A card never navigates itself away.
public enum CardNavigation {
    public enum Target: Equatable, Sendable {
        case mainFrame, subframe
        /// A link or script asked for a new window; there is none to give it.
        case newWindow
    }

    public enum Verdict: Equatable, Sendable {
        case allow, cancel
    }

    public struct Request: Equatable, Sendable {
        public var url: String
        public var target: Target
        /// The app loading the card's own page.
        public var pageLoad: Bool

        public init(url: String, target: Target, pageLoad: Bool) {
            self.url = url
            self.target = target
            self.pageLoad = pageLoad
        }
    }

    /// A markdown doc: its page loads once and stays. No navigation opens the
    /// browser — a page the doc frames can ask for one with no click at all —
    /// so a link is opened from the page's own click instead (`ExternalLink`).
    /// A frame embedded by raw HTML may load a web page, as in the Tauri app,
    /// and never the card scheme: a card document framed here is not
    /// sandboxed, and would read any other local file framed beside it.
    public static func doc(_ request: Request) -> Verdict {
        if request.pageLoad { return .allow }
        guard request.target == .subframe else { return .cancel }
        return ExternalLink.isHTTP(href: request.url) || inlineFrames.contains(request.url) ? .allow : .cancel
    }

    private static let inlineFrames: Set<String> = ["about:blank", "about:srcdoc"]

    /// An HTML card: the host page loads once, and the frame inside it only
    /// ever holds a card document.
    public static func htmlCard(_ request: Request) -> Verdict {
        switch request.target {
        case .mainFrame:
            return request.pageLoad ? .allow : .cancel
        case .subframe:
            return request.url.hasPrefix(CardProtocol.uriPrefix) ? .allow : .cancel
        case .newWindow:
            return .cancel
        }
    }
}
