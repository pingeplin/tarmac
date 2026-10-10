import Foundation

/// Where the card shim's `<script>` goes (spec 2610.0011): after the file's leading
/// doctype, so the browser's parser gives the file the mode its doctype names. The
/// doctype is found, never read: the mode is the browser's call. Only what the
/// tokenizer skips before a doctype is skipped here (a BOM, white space, `<!-- -->`
/// and `<?…>`); any other start, including a comment form the rule does not know,
/// puts the shim at the start of the file, after a BOM, and leaves the document in
/// quirks mode, as it was.
public enum ShimPlacement {
    /// The byte offset, from the first byte of `file`, at which the shim goes.
    public static func offset(in file: Data) -> Int {
        file.withUnsafeBytes { bytes in
            let bom = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
            return doctypeEnd(in: bytes, from: bom) ?? bom
        }
    }

    private static func doctypeEnd(in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        var p = start
        while p < bytes.count {
            if whiteSpace.contains(bytes[p]) {
                p += 1
            } else if matches(bytes, at: p, "<!--") {
                guard let end = commentEnd(in: bytes, opening: p) else { return nil }
                p = end
            } else if matches(bytes, at: p, "<?") {
                guard let close = firstGreaterThan(in: bytes, from: p + 2) else { return nil }
                p = close + 1
            } else {
                break
            }
        }
        guard matches(bytes, at: p, "<!"), matchesIgnoringCase(bytes, at: p + 2, "doctype"),
              let close = firstGreaterThan(in: bytes, from: p + 9) else { return nil }
        return close + 1
    }

    /// `-->` may start two bytes in (`<!-->`); `--!>` four (`<!---!>` is not closed).
    private static func commentEnd(in bytes: UnsafeRawBufferPointer, opening p: Int) -> Int? {
        var i = p + 2
        while i < bytes.count {
            if matches(bytes, at: i, "-->") { return i + 3 }
            if i >= p + 4, matches(bytes, at: i, "--!>") { return i + 4 }
            i += 1
        }
        return nil
    }

    private static func firstGreaterThan(in bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        (start..<max(start, bytes.count)).first { bytes[$0] == greaterThan }
    }

    private static func matches(_ bytes: UnsafeRawBufferPointer, at p: Int, _ text: StaticString) -> Bool {
        let expected = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
        return p + expected.count <= bytes.count && expected.indices.allSatisfy { bytes[p + $0] == expected[$0] }
    }

    /// `text` is lower-case ASCII letters, so setting bit 5 folds exactly the upper-case ones.
    private static func matchesIgnoringCase(_ bytes: UnsafeRawBufferPointer, at p: Int, _ text: StaticString) -> Bool {
        let expected = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
        return p + expected.count <= bytes.count && expected.indices.allSatisfy { bytes[p + $0] | 0x20 == expected[$0] }
    }

    private static let greaterThan = UInt8(ascii: ">")
    private static let whiteSpace: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D, 0x20]
}
