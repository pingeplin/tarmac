import Foundation

/// Whether a document is JSON that `serde_json::from_slice` would accept: a
/// grammar check, not a parser. `JSONDecoder` is far more forgiving (UTF-16 and
/// UTF-32, a trailing comma, `01`, lone surrogates, raw control characters in a
/// string, nesting to 512), so a file that the Rust app treats as damaged would
/// be read as valid here without this.
///
/// The rules are serde_json's: UTF-8 only; whitespace is space, tab, LF and CR;
/// strings hold no raw byte below U+0020 and only the RFC 8259 escapes, with
/// surrogates paired; numbers follow the RFC grammar and must fit a finite
/// `Double`; at most 127 nested arrays and objects, the document's own included.
enum StrictJSON {
    static let maxDepth = 127

    static func isValid(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard String(validating: bytes, as: UTF8.self) != nil else { return false }
        var reader = Reader(bytes: bytes)
        return reader.document()
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func take() -> UInt8? {
            guard let byte = peek else { return nil }
            index += 1
            return byte
        }

        mutating func eat(_ scalar: Unicode.Scalar) -> Bool {
            guard peek == UInt8(ascii: scalar) else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func document() -> Bool {
            skipWhitespace()
            guard value(depth: 0) else { return false }
            skipWhitespace()
            return index == bytes.count
        }

        /// `depth` is the number of containers already open around this value.
        mutating func value(depth: Int) -> Bool {
            switch peek {
            case UInt8(ascii: "{"): return container(close: "}", depth: depth) { $0.member(depth: depth + 1) }
            case UInt8(ascii: "["): return container(close: "]", depth: depth) { $0.value(depth: depth + 1) }
            case UInt8(ascii: "\""): return string()
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        /// Elements are required after every comma, which is what rejects a
        /// trailing one.
        mutating func container(close: Unicode.Scalar, depth: Int, element: (inout Reader) -> Bool) -> Bool {
            guard depth < StrictJSON.maxDepth else { return false }
            index += 1
            skipWhitespace()
            if eat(close) { return true }
            while true {
                guard element(&self) else { return false }
                skipWhitespace()
                if eat(close) { return true }
                guard eat(",") else { return false }
                skipWhitespace()
            }
        }

        mutating func member(depth: Int) -> Bool {
            guard peek == UInt8(ascii: "\""), string() else { return false }
            skipWhitespace()
            guard eat(":") else { return false }
            skipWhitespace()
            return value(depth: depth)
        }

        mutating func literal(_ word: String) -> Bool {
            let expected = Array(word.utf8)
            guard bytes[index...].starts(with: expected) else { return false }
            index += expected.count
            return true
        }

        /// Whatever follows the number is the caller's to judge, so `01` and `1.5.2`
        /// fail on their second token.
        mutating func number() -> Bool {
            let start = index
            _ = eat("-")
            guard eat("0") || digits() else { return false }
            if eat(".") { guard digits() else { return false } }
            if eat("e") || eat("E") {
                _ = eat("+") || eat("-")
                guard digits() else { return false }
            }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self))?.isFinite == true
        }

        mutating func digits() -> Bool {
            let start = index
            while let byte = peek, (0x30...0x39).contains(byte) { index += 1 }
            return index > start
        }

        mutating func string() -> Bool {
            index += 1
            while let byte = take() {
                switch byte {
                case UInt8(ascii: "\""): return true
                case UInt8(ascii: "\\"): guard escape() else { return false }
                case ..<0x20: return false
                default: continue
                }
            }
            return false
        }

        mutating func escape() -> Bool {
            guard let kind = take() else { return false }
            if "\"\\/bfnrt".utf8.contains(kind) { return true }
            return kind == UInt8(ascii: "u") && unicodeEscape()
        }

        mutating func unicodeEscape() -> Bool {
            guard let unit = hex4() else { return false }
            switch unit {
            case 0xD800...0xDBFF:
                guard take() == UInt8(ascii: "\\"), take() == UInt8(ascii: "u"), let low = hex4() else { return false }
                return (0xDC00...0xDFFF).contains(low)
            case 0xDC00...0xDFFF:
                return false
            default:
                return true
            }
        }

        mutating func hex4() -> UInt32? {
            var unit: UInt32 = 0
            for _ in 0..<4 {
                guard let byte = take(), let digit = Self.hexValue(byte) else { return nil }
                unit = unit << 4 | digit
            }
            return unit
        }

        static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: return UInt32(byte - 0x30)
            case 0x41...0x46: return UInt32(byte - 0x41 + 10)
            case 0x61...0x66: return UInt32(byte - 0x61 + 10)
            default: return nil
            }
        }
    }
}
