/// `std::path::Path::extension`, the semantics `ImageProtocol`'s allowlist is
/// specified against — not `NSString.pathExtension`, which disagrees on trailing
/// slashes and `.`/`..` components.
///
/// The name is the last component once empty and `.` components are dropped; a
/// `..` there has no name. Its extension is what follows the last `.`, unless that
/// `.` is the name's first byte (`.png` is a hidden file, not an extension).
/// Everything runs on UTF-8 bytes: Rust splits at the byte, whereas a Swift
/// `Character` fuses a `.` with a following combining mark and hides it.
enum RustPathExtension {
    private static let slash: UInt8 = 0x2F
    private static let dot: UInt8 = 0x2E

    static func of(_ path: String) -> String? {
        let name = path.utf8
            .split(separator: slash)
            .last { !$0.elementsEqual([dot]) }
        guard let name, !name.elementsEqual([dot, dot]) else { return nil }
        guard let lastDot = name.lastIndex(of: dot), lastDot != name.startIndex else { return nil }
        return String(decoding: name[name.index(after: lastDot)...], as: UTF8.self)
    }
}
