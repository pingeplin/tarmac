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
        let directory = Array(components(html).dropLast())
        let path = components(name, onto: name.utf8.first == slash ? [] : directory)
        let text = "/" + path.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
        // A trailing slash names a directory, and no path holds a NUL.
        if name.utf8.last == slash || name.utf8.contains(0) || path == directory {
            return .refused(path: text, reason: namesNoFile)
        }
        if path.dropLast().elementsEqual(directory) { return .file(text) }
        return .refused(path: text, reason: path.starts(with: directory) ? inSubdirectory : outside)
    }

    /// Whether `file` is in the directory that holds `html`. Both are
    /// resolved paths and are taken as given: the bytes before the last
    /// slash of each are compared, and nothing is worked out again.
    static func isBeside(_ file: String, html: String) -> Bool {
        func directory(_ path: String) -> ArraySlice<UInt8> {
            let bytes = Array(path.utf8)
            return bytes[..<(bytes.lastIndex(of: slash) ?? 0)]
        }
        return directory(file).elementsEqual(directory(html))
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
