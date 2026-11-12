/// Where an HTML card's `tarmac-data` name leads (specs 2611.0002, 2611.0005),
/// judged in the text alone: no file-system call, so a name is never followed
/// to see where it goes. The read judges the resolved file again
/// (`CardDataRead`).
enum CardDataPath {
    enum Judgement: Equatable, Sendable {
        case file(String)
        /// `path` is the normalised one; the reason does not repeat it.
        case refused(path: String, reason: String)
    }

    static let outside = "outside this card's directory"
    static let namesNoFile = "names no file"
    static let hidden = "in a hidden file or directory"

    /// `html` is the card's file, an absolute and resolved path. The file
    /// must be in its directory or in one under it, with no hidden component
    /// below that directory.
    static func dataFile(html: String, name: String) -> Judgement {
        let directory = Array(components(html).dropLast())
        let path = components(name, onto: name.utf8.first == slash ? [] : directory)
        let text = "/" + path.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
        // A trailing slash names a directory, and no path holds a NUL.
        if name.utf8.last == slash || name.utf8.contains(0) || path == directory {
            return .refused(path: text, reason: namesNoFile)
        }
        guard path.starts(with: directory) else { return .refused(path: text, reason: outside) }
        if isHidden(path.dropFirst(directory.count)) { return .refused(path: text, reason: hidden) }
        return .file(text)
    }

    /// The components of `file` below the directory that holds `html`, or
    /// nil when `file` is not under it. Both are resolved paths and are taken
    /// as given: each component of the directory equals the file's at the
    /// same place, as bytes, and a file with an empty, `.` or `..` component
    /// is under no directory, since nothing is worked out again.
    static func below(_ file: String, html: String) -> ArraySlice<ArraySlice<UInt8>>? {
        let parts = Array(file.utf8).split(separator: slash, omittingEmptySubsequences: false)
        let directory = Array(html.utf8).split(separator: slash, omittingEmptySubsequences: false).dropLast()
        let unworked = parts.dropFirst().allSatisfy {
            !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8)
        }
        guard unworked, parts.count > directory.count, parts.starts(with: directory) else { return nil }
        return parts.dropFirst(directory.count)
    }

    /// A component is hidden when its first byte is a dot.
    static func isHidden(_ components: some Sequence<ArraySlice<UInt8>>) -> Bool {
        components.contains { $0.first == UInt8(ascii: ".") }
    }

    private static let slash = UInt8(ascii: "/")

    /// The path's components after those of `base`, as bytes: `.` and empty
    /// components dropped, and `..` taking off the one before, as POSIX
    /// resolves them, with no look at what is on disk. Bytes, because a file
    /// system compares them: a `String` joins a `/` to a combining mark that
    /// follows it, and takes two forms of one letter for equal.
    private static func components(_ path: String, onto base: [ArraySlice<UInt8>] = []) -> [ArraySlice<UInt8>] {
        var components = base
        for component in Array(path.utf8).split(separator: slash) {
            if component.elementsEqual(".".utf8) { continue }
            if component.elementsEqual("..".utf8) {
                _ = components.popLast()
            } else {
                components.append(component)
            }
        }
        return components
    }
}
