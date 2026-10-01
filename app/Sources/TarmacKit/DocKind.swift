/// Doc-kind routing for doc cards (spec 2607.0004): HTML cards render in a
/// sandboxed web view, everything else as markdown. The kind is derived from the
/// path extension, never stored — the doc model and the wire protocol know
/// nothing about it.
public enum DocKind: Equatable, Sendable {
    case markdown, html

    /// Case-insensitive `.html` / `.htm` is HTML. Dotfiles (`.html`) and
    /// trailing-dot names have no extension and route to markdown, as with Node's
    /// `path.extname` — which `NSString.pathExtension` does not match for dotfiles.
    public init(path: String) {
        let scalars = path.unicodeScalars
        let nameStart = scalars.lastIndex(of: "/").map(scalars.index(after:)) ?? scalars.startIndex
        let name = scalars[nameStart...]
        guard let dot = name.lastIndex(of: "."),
              dot > name.startIndex,
              name.index(after: dot) < name.endIndex
        else {
            self = .markdown
            return
        }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        self = ext == "html" || ext == "htm" ? .html : .markdown
    }
}

/// `tarmac-card://` addressing for HTML doc cards and for the images of markdown
/// doc cards (spec 2609.0014).
public enum CardURL {
    /// `doc` for HTML cards, `img` for markdown doc-card images.
    public enum Host: String, Sendable {
        case doc, img
    }

    /// The whole absolute path is ONE percent-encoded segment under `host`; `?v=`
    /// is a cache-buster only (the handler ignores it and serves current bytes),
    /// and bumping it on a file event is what forces the page reload. A pure
    /// function of its inputs: a refresh with an unchanged mtime must produce the
    /// same URL, or it would reload an HTML card and lose its JS state (#99).
    public static func src(path: String, mtimeMs: UInt64?, host: Host = .doc) -> String {
        "tarmac-card://\(host.rawValue)/\(encodeURIComponent(path))?v=\(mtimeMs ?? 0)"
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()".utf8)
    private static let hexDigits = Array("0123456789ABCDEF")

    /// Exactly the characters `encodeURIComponent` leaves alone — none of the
    /// `CharacterSet` URL presets match, `urlPathAllowed` keeping `/`.
    private static func encodeURIComponent(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) {
                out.append(Character(Unicode.Scalar(byte)))
            } else {
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }
}
