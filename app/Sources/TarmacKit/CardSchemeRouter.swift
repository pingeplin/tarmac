import Foundation

/// The single entry a `WKURLSchemeHandler` for `tarmac-card` calls. It covers
/// what Tauri's stack does around `respond_card_scheme` (`lib.rs`) for every URL
/// the app builds: wry forms the request with `http::Uri`, which drops a
/// `#fragment` — and a WKURLSchemeTask URL keeps it — and then the `img` host
/// goes to the image handler while every other host is the card handler's to
/// answer 400.
///
/// Two things `http::Uri` does are not reproduced, neither reachable from an
/// app-built URL: it writes a missing path as `/` (so `tarmac-card://doc` is an
/// "empty path" 400 there and a "malformed" 400 here), and it refuses some URLs
/// outright (raw control characters, a 64 KiB URL), which wry answers with a
/// bare 404 before any handler runs.
///
/// Feed it the task URL's `absoluteString`, never `.path`, which percent-decodes.
/// `CardProtocol.decodeSchemePath` stays byte-identical to the Rust function and
/// treats `#` as path text; only a `%23` can name a `#` in a file, here as in Rust.
public enum CardSchemeRouter {
    public enum Route: Equatable, Sendable {
        case doc(CardProtocol.Resolution)
        case image(ImageProtocol.Resolution)
    }

    public static func route(url: String) -> Route {
        let uri = withoutFragment(url)
        return ImageProtocol.owns(uri: uri) ? .image(ImageProtocol.resolve(uri: uri)) : .doc(CardProtocol.resolve(uri: uri))
    }

    /// Resolves `url`, reads through `read` only when a file is to be served, and
    /// returns the response to hand to WebKit. `read` is the host's file I/O and
    /// blocks, so call this off the main thread. This is the whole scheme, as
    /// Tauri's one handler answers it; a web view is given `respond(…serving:…)`.
    static func respond(url: String, shim: String, read: (String) -> Result<Data, any Error>) -> CardProtocol.Response {
        switch route(url: url) {
        case .doc(.reject(let response)), .image(.reject(let response)):
            return response
        case .doc(.read(let path)):
            return CardProtocol.respond(path: path, contents: read(path), shim: shim)
        case .image(.read(let path, let contentType)):
            return ImageProtocol.respond(path: path, contentType: contentType, contents: read(path))
        }
    }

    /// The response for a web view that is served `host` and nothing else: an
    /// HTML card's loads its document, a markdown doc's its images. A markdown
    /// doc that framed a card document would have it run unsandboxed at the
    /// scheme's origin, where it reads any other file the doc framed. A URL of
    /// the other host is refused before the disk is touched.
    ///
    /// `headers` are the request's. A page loads its own frames and images
    /// without an `Origin`; XHR and fetch carry one. No page the app loads
    /// reads this scheme by script, and a web page a markdown doc frames would:
    /// WebKit lets its synchronous XHR through with no CORS check. So a request
    /// that names its origin is refused, also before the disk is touched.
    public static func respond(
        url: String, headers: [String: String], shim: String, serving host: CardURL.Host,
        read: (String) -> Result<Data, any Error>
    ) -> CardProtocol.Response {
        guard !namesItsOrigin(headers) else {
            return CardProtocol.textResponse(status: 403, body: "not served to a script")
        }
        let asked: CardURL.Host
        switch route(url: url) {
        case .doc: asked = .doc
        case .image: asked = .img
        }
        guard asked == host else {
            return CardProtocol.textResponse(status: 403, body: "the \(asked.rawValue) host is not served to this card")
        }
        return respond(url: url, shim: shim, read: read)
    }

    /// Header names are ASCII and matched without regard to case.
    private static func namesItsOrigin(_ headers: [String: String]) -> Bool {
        headers.keys.contains { $0.lowercased() == "origin" }
    }

    /// Cut at the first `#`, `?` after it included — what `http::Uri` keeps.
    static func withoutFragment(_ url: String) -> String {
        String(decoding: url.utf8.prefix { $0 != 0x23 }, as: UTF8.self)
    }
}
