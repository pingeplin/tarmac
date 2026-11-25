/// One doc path, equal to another only when their UTF-8 bytes are (spec
/// 2611.0034). The daemon's registry keys docs by bytes; a Swift `String`
/// compares by canonical equivalence, which would join an NFC and an NFD
/// name that a file system can keep as two files.
public struct DocPath: Hashable, Sendable {
    public let string: String

    public init(_ string: String) {
        self.string = string
    }

    public static func == (lhs: DocPath, rhs: DocPath) -> Bool {
        lhs.string.utf8.elementsEqual(rhs.string.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in string.utf8 { hasher.combine(byte) }
    }
}
