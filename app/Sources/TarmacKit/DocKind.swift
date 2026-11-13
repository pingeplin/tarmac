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
