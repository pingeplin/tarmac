import Foundation

/// Classifier for clickable card links. Only absolute http(s) URLs may be handed
/// to the OS opener; anything else (relative hrefs, mailto:, javascript:) stays
/// inert so a card webview never navigates itself away.
public enum ExternalLink {
    /// `href` as authored in a card, cleaned the way the URL standard cleans it
    /// before parsing, then required to name an http(s) URL with a host.
    public static func isHTTP(href: String) -> Bool {
        guard let url = URL(string: urlStandardCleaned(href)) else { return false }
        return isHTTP(url)
    }

    /// The host requirement is what rejects `https://` and `https:`, and the port
    /// range what rejects `:99999`, which `URL` parses happily but nothing could open.
    /// Not public: every caller goes through `isHTTP(href:)` and its cleaning.
    static func isHTTP(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if let port = url.port, !(0...65535).contains(port) { return false }
        return !(url.host ?? "").isEmpty
    }

    /// Strips leading/trailing C0 controls and spaces and removes every tab and
    /// newline, so `URL(string:)` sees what a browser would.
    private static func urlStandardCleaned(_ href: String) -> String {
        var scalars = href.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        let start = scalars.firstIndex { $0.value > 0x20 } ?? scalars.endIndex
        var cleaned = String.UnicodeScalarView()
        cleaned.append(contentsOf: scalars[start...])
        return String(cleaned)
    }
}
