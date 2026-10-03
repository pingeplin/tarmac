import Foundation

/// Doc-card `<img src>` resolution (spec 2609.0014). A markdown doc renders into
/// the app's own document, so a doc-relative `src` would resolve against the app
/// origin instead of the doc's directory; a local `src` is therefore resolved to
/// an absolute file path here and re-addressed by the view layer.
///
/// The rules read Unicode scalars, never `Character`s: `\r\n`, or a `/` followed by
/// a combining mark, is a single `Character` and would slip past a character-wise
/// trim or split.
public enum DocImage {
    /// The absolute on-disk path a doc image `src` names, or nil when `src` is not a
    /// local file reference (the caller leaves it unchanged). `docPath` is the
    /// doc's absolute path.
    public static func localPath(src: String, docPath: String) -> String? {
        guard let ref = localRef(trimmingASCIIWhitespace(src)) else { return nil }
        // Strip before decoding, so %23 and %3F survive as a literal # or ? in the name.
        let scalars = ref.path.unicodeScalars
        let cut = scalars.firstIndex { $0 == "?" || $0 == "#" } ?? scalars.endIndex
        let local = String(scalars[..<cut])
        if local.isEmpty { return nil }
        let decoded = local.removingPercentEncoding ?? local
        // The doc's directory is a real path, not URL text: joined literally, never decoded.
        return normalize(ref.isRelative ? directory(of: docPath) + decoded : decoded)
    }

    /// The `src` a doc-card `<img>` carries: a local file goes to the `img` host
    /// of `tarmac-card://`, cache-busted by the doc's change time, and anything
    /// else stays as written.
    public static func src(_ src: String, docPath: String, mtimeMs: UInt64?) -> String {
        guard let path = localPath(src: src, docPath: docPath) else { return src }
        return CardURL.src(path: path, mtimeMs: mtimeMs, host: .img)
    }

    private struct LocalRef {
        var path: String
        var isRelative: Bool
    }

    private static func localRef(_ src: String) -> LocalRef? {
        let scalars = src.unicodeScalars
        let scheme = leadingScheme(scalars)
        if let scheme, scheme.name.lowercased() != "file" { return nil }
        if scalars.starts(with: "//".unicodeScalars) { return nil }
        if let scheme {
            let afterScheme = scalars[scheme.end...]
            guard afterScheme.starts(with: "//".unicodeScalars) else { return nil }
            let authorityAndPath = afterScheme.dropFirst(2)
            let slash = authorityAndPath.firstIndex(of: "/")
            let host = String(authorityAndPath[..<(slash ?? authorityAndPath.endIndex)])
            if !host.isEmpty && host != "localhost" { return nil }
            return LocalRef(path: slash.map { String(authorityAndPath[$0...]) } ?? "", isRelative: false)
        }
        return LocalRef(path: src, isRelative: !scalars.starts(with: "/".unicodeScalars))
    }

    /// `^([A-Za-z][A-Za-z0-9+.-]*):` — the scheme name and the index after its colon.
    private static func leadingScheme(
        _ scalars: String.UnicodeScalarView
    ) -> (name: String, end: String.UnicodeScalarView.Index)? {
        guard let first = scalars.first, isASCIILetter(first) else { return nil }
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == ":" { return (String(scalars[..<index]), scalars.index(after: index)) }
            guard isASCIILetter(scalar) || ("0"..."9").contains(scalar) || "+.-".unicodeScalars.contains(scalar)
            else { return nil }
            index = scalars.index(after: index)
        }
        return nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// The HTML/URL-standard set — tab, LF, FF, CR, space. A general trim would also
    /// strip VT and Unicode spaces.
    private static func trimmingASCIIWhitespace(_ text: String) -> String {
        let isSpace: (Unicode.Scalar) -> Bool = { $0 == "\t" || $0 == "\n" || $0 == "\u{0C}" || $0 == "\r" || $0 == " " }
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// The doc's directory including its trailing slash.
    private static func directory(of docPath: String) -> String {
        let scalars = docPath.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return "" }
        return String(scalars[...slash])
    }

    /// Resolves `.` and `..` segments, keeping empty ones (`%2Fx.png` → `/r//x.png`,
    /// which POSIX reads as `/`) and never climbing above the root. Not
    /// `standardizingPath`, which collapses `//`.
    private static func normalize(_ path: String) -> String {
        var segments: [String] = []
        for segment in path.unicodeScalars.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(segment)
            if name == "." { continue }
            if name == ".." { segments.removeLast(segments.isEmpty ? 0 : 1) } else { segments.append(name) }
        }
        return "/" + segments.joined(separator: "/")
    }
}
