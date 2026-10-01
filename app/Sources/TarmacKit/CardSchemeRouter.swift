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
    /// blocks, so call this off the main thread.
    public static func respond(url: String, shim: String, read: (String) -> Result<Data, any Error>) -> CardProtocol.Response {
        switch route(url: url) {
        case .doc(.reject(let response)), .image(.reject(let response)):
            return response
        case .doc(.read(let path)):
            return CardProtocol.respond(path: path, contents: read(path), shim: shim)
        case .image(.read(let path, let contentType)):
            return ImageProtocol.respond(path: path, contentType: contentType, contents: read(path))
        }
    }

    /// Cut at the first `#`, `?` after it included — what `http::Uri` keeps.
    static func withoutFragment(_ url: String) -> String {
        String(decoding: url.utf8.prefix { $0 != 0x23 }, as: UTF8.self)
    }
}
