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
    /// A frame embedded by raw HTML loads what it likes.
    public static func doc(_ request: Request) -> Verdict {
        request.pageLoad || request.target == .subframe ? .allow : .cancel
    }

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
