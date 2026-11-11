/// Where an HTML card's `tarmac-data` name leads (spec 2611.0002), judged in
/// the text alone: no file-system call, so a name is never followed to see
/// where it goes. The read judges the resolved file again (`CardDataRead`).
enum CardDataPath {
    enum Judgement: Equatable, Sendable {
        case file(String)
        /// `path` is the normalised one; the reason does not repeat it.
        case refused(path: String, reason: String)
    }

    static let inSubdirectory = "in a subdirectory: not read yet"
    static let outside = "outside this card's directory"
    static let namesNoFile = "names no file"

    /// `html` is the card's file, an absolute and resolved path.
    static func dataFile(html: String, name: String) -> Judgement {
        let directory = parent(of: html)
        let path = normalised(name.hasPrefix("/") ? name : directory + "/" + name)
        // A trailing slash names a directory, and no path holds a NUL.
        if name.hasSuffix("/") || name.utf8.contains(0) || path == directory || path == "/" {
            return .refused(path: path, reason: namesNoFile)
        }
        if parent(of: path) == directory { return .file(path) }
        let under = directory == "/" ? "/" : directory + "/"
        return .refused(path: path, reason: path.hasPrefix(under) ? inSubdirectory : outside)
    }

    /// The directory that holds `path`, an absolute path with no trailing
    /// slash.
    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// `.` and empty components dropped, and `..` taking off the one before,
    /// as POSIX resolves them, with no look at what is on disk.
    private static func normalised(_ absolute: String) -> String {
        var components: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
