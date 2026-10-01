/// Where a card's web view may navigate. A card never navigates itself away.
public enum CardNavigation {
    public enum Target: Equatable, Sendable {
        case mainFrame, subframe
        /// A link or script asked for a new window; there is none to give it.
        case newWindow
    }

    public enum Cause: Equatable, Sendable {
        /// The app loading the card's own page.
        case pageLoad
        case linkClick
        case other
    }

    public enum Verdict: Equatable, Sendable {
        case allow, cancel
        /// Cancel, and hand the URL to the system browser.
        case openExternally
    }

    public struct Request: Equatable, Sendable {
        public var url: String
        public var target: Target
        public var cause: Cause

        public init(url: String, target: Target, cause: Cause) {
            self.url = url
            self.target = target
            self.cause = cause
        }
    }

    /// A markdown doc: a clicked http(s) link opens in the browser and every
    /// other href is inert (spec 2607.0005). Raw HTML can hold a refresh or a
    /// form, so nothing but a click reaches the browser. A frame embedded by
    /// raw HTML loads what it likes.
    public static func doc(_ request: Request) -> Verdict {
        if request.cause == .pageLoad { return .allow }
        if request.target == .subframe { return .allow }
        return request.cause == .linkClick && ExternalLink.isHTTP(href: request.url) ? .openExternally : .cancel
    }

    /// An HTML card: the host page loads once, and the frame inside it only
    /// ever holds a card document.
    public static func htmlCard(_ request: Request) -> Verdict {
        switch request.target {
        case .mainFrame:
            return request.cause == .pageLoad ? .allow : .cancel
        case .subframe:
            return request.url.hasPrefix(CardProtocol.uriPrefix) ? .allow : .cancel
        case .newWindow:
            return .cancel
        }
    }
}
