import Foundation

/// The `tarmac-card://doc/` host (spec 2607.0004): what to serve for an HTML doc
/// card, as `desktop/src-tauri/src/card_protocol.rs` decides it. Pure — the scheme
/// handler reads the file between `resolve` and `respond`, hands in the bundled
/// shim, and forwards the `Response` to WebKit.
///
/// The request URI is parsed as bytes, never through `URL` or `String`'s Unicode
/// conveniences, so every input gets the answer the Rust gives (the parity tests
/// pin the ones that differ). It takes the URI as Rust's `respond` receives it, so
/// a `#` is path text here. Tauri's `http::Uri` drops the fragment before that
/// point and a WKURLSchemeTask URL does not: a host calls `CardSchemeRouter`, which
/// cuts it first, rather than this type directly.
///
/// Same filesystem trust model as `commands::read_doc`: the path is used as named,
/// no canonicalization, no jail — there is no docs-root concept, so this is a
/// non-goal, not an oversight. Open it with POSIX semantics, not `URL(fileURLWithPath:)`,
/// which drops a trailing slash that std would reject with ENOTDIR.
public enum CardProtocol {
    /// Byte-exact per spec 2607.0004's Interface Contract — do not reformat.
    public static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:"

    public static let uriPrefix = "tarmac-card://doc/"

    public struct Response: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data

        public init(status: Int, headers: [String: String], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// User-facing 400 text, not a diagnostic for the app to branch on.
    public struct DecodeError: Error, Equatable, Sendable {
        public let message: String
    }

    public enum Resolution: Equatable, Sendable {
        /// Read `path` as given and pass the bytes to `respond`.
        case read(path: String)
        case reject(Response)
    }

    /// Decode the percent-encoded path segment after `prefix`, up to any `?`.
    /// Shared by every `tarmac-card://` host. A `%` not followed by two hex digits
    /// stays a literal `%`; only invalid UTF-8 after decoding is an error. A `#` is
    /// ordinary path text.
    public static func decodeSchemePath(_ uri: String, prefix: String) -> Result<String, DecodeError> {
        let bytes = Array(uri.utf8)
        guard bytes.starts(with: prefix.utf8) else {
            return .failure(DecodeError(message: "malformed tarmac-card URI: \(uri)"))
        }
        let encoded = bytes.dropFirst(prefix.utf8.count).prefix { $0 != questionMark }
        guard !encoded.isEmpty else { return .failure(DecodeError(message: "empty path")) }
        let decoded = percentDecoded(encoded)
        if let failure = utf8Failure(decoded) {
            return .failure(DecodeError(message: "invalid UTF-8 in path: \(failure)"))
        }
        return .success(String(decoding: decoded, as: UTF8.self))
    }

    static func textResponse(status: Int, body: String) -> Response {
        Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(body.utf8))
    }

    static func unreadable(path: String, reason: String) -> Response {
        textResponse(status: 404, body: "\(path): \(reason)")
    }

    /// std refuses to open a name holding a NUL; a POSIX `open` would silently stop
    /// at it and read a different file, so the answer is fixed here, not left to the
    /// host's I/O.
    static func rejectingNul(path: String) -> Response? {
        path.utf8.contains(0) ? unreadable(path: path, reason: "file name contained an unexpected NUL byte") : nil
    }

    /// 400 on a malformed or undecodable URI, otherwise the path to read.
    public static func resolve(uri: String) -> Resolution {
        switch decodeSchemePath(uri, prefix: uriPrefix) {
        case .failure(let error):
            return .reject(textResponse(status: 400, body: error.message))
        case .success(let path):
            return rejectingNul(path: path).map(Resolution.reject) ?? .read(path: path)
        }
    }

    /// 404 if the file could not be read, otherwise 200: the shim, in its own
    /// `<script>`, strictly before the first file byte — no content sniffing, so a
    /// `<!DOCTYPE>` or a BOM changes nothing.
    public static func respond(path: String, contents: Result<Data, any Error>, shim: String) -> Response {
        switch contents {
        case .failure(let error):
            return unreadable(path: path, reason: error.localizedDescription)
        case .success(let file):
            return Response(
                status: 200,
                headers: ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": csp],
                body: Data("<script>\(shim)</script>\n".utf8) + file
            )
        }
    }

    private static let questionMark: UInt8 = 0x3F
    private static let percent: UInt8 = 0x25

    private static func percentDecoded(_ encoded: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(encoded)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == percent, i + 2 < bytes.count,
               let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) {
                out.append(high << 4 | low)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Rust's `Utf8Error` text for the first invalid sequence in `bytes`, or `nil`
    /// when they are valid. Mirrors core's validation — surrogates, overlong forms
    /// and anything above U+10FFFF are errors — and its two phrasings, so the 400
    /// body reads the same on both sides.
    private static func utf8Failure(_ bytes: [UInt8]) -> String? {
        var index = 0
        while index < bytes.count {
            let start = index
            let first = bytes[index]
            index += 1
            if first < 0x80 { continue }

            func invalid(_ length: Int) -> String { "invalid utf-8 sequence of \(length) bytes from index \(start)" }
            let incomplete = "incomplete utf-8 byte sequence from index \(start)"
            func next() -> UInt8? {
                defer { index += 1 }
                return index < bytes.count ? bytes[index] : nil
            }
            func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

            switch first {
            case 0xC2...0xDF:
                guard let b1 = next() else { return incomplete }
                if !isContinuation(b1) { return invalid(1) }
            case 0xE0...0xEF:
                guard let b1 = next() else { return incomplete }
                let valid: ClosedRange<UInt8> = switch first {
                case 0xE0: 0xA0...0xBF
                case 0xED: 0x80...0x9F
                default: 0x80...0xBF
                }
                if !valid.contains(b1) { return invalid(1) }
                guard let b2 = next() else { return incomplete }
                if !isContinuation(b2) { return invalid(2) }
            case 0xF0...0xF4:
                guard let b1 = next() else { return incomplete }
                let valid: ClosedRange<UInt8> = switch first {
                case 0xF0: 0x90...0xBF
                case 0xF4: 0x80...0x8F
                default: 0x80...0xBF
                }
                if !valid.contains(b1) { return invalid(1) }
                guard let b2 = next() else { return incomplete }
                if !isContinuation(b2) { return invalid(2) }
                guard let b3 = next() else { return incomplete }
                if !isContinuation(b3) { return invalid(3) }
            default:
                return invalid(1)
            }
        }
        return nil
    }
}
