import Foundation

/// A markdown doc's front matter (spec 2611.0022, D1–D3): the fields a block
/// between two fences at the doc's top holds, and the body after it. Not a
/// YAML parser: a line it does not know joins the field above it, as a line
/// of its text or as an item of its list.
public enum DocFrontMatter {
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])
    }

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: Value

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    public static func split(_ markdown: String) -> (fields: [Field], body: String) {
        // Split on UTF-8: "\r\n" is one Character, and the body must be the
        // doc's own tail, never lines joined again.
        let firstEnd = markdown.utf8.firstIndex(of: UInt8(ascii: "\n")) ?? markdown.utf8.endIndex
        guard isFence(line(markdown.utf8[..<firstEnd]), marks: ["---"]) else { return ([], markdown) }
        let lines = markdown.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        guard let close = lines.indices.dropFirst().first(where: { isFence(line(lines[$0]), marks: ["---", "..."]) })
        else { return ([], markdown) }
        let block = lines[1..<close].map(line)
        guard block.contains(where: { key(of: $0) != nil }), block.allSatisfy(isAllowed) else { return ([], markdown) }

        let end = lines[close].endIndex
        let body = end == markdown.utf8.endIndex ? "" : String(markdown[markdown.utf8.index(after: end)...])
        return (fields(block), body)
    }

    /// The fields as the page takes them (D19): `[key, value]`, a text as a
    /// string and a list as an array of strings.
    public static func page(_ fields: [Field]) -> [[Any]] {
        fields.map { field in
            switch field.value {
            case .text(let text): [field.key, text]
            case .list(let items): [field.key, items]
            }
        }
    }

    private static func line(_ bytes: Substring.UTF8View) -> String {
        let line = String(Substring(bytes))
        return line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    private static func isFence(_ line: String, marks: [String]) -> Bool {
        marks.contains { line.hasPrefix($0) && line.dropFirst($0.count).allSatisfy { $0 == " " } }
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func isAllowed(_ line: String) -> Bool {
        isBlank(line) || key(of: line) != nil || item(of: line) != nil
            || line.first == " " || line.first == "\t" || line.first == "#"
    }

    /// The key and the rest of a key line: a key ends at the first `:`, which
    /// ends the line or is followed by a space.
    private static func key(of line: String) -> (key: String, rest: Substring)? {
        guard let colon = line.firstIndex(of: ":"), let first = line.unicodeScalars.first,
            first == "_" || isLetterOrDigit(first)
        else { return nil }
        let rest = line[line.index(after: colon)...]
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (trimmed(line[..<colon]), rest)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: true
        default: false
        }
    }

    /// The item of `- item` at any indent, trimmed and unquoted.
    private static func item(of line: String) -> String? {
        let indented = line.drop { $0 == " " || $0 == "\t" }
        guard indented.first == "-" else { return nil }
        let rest = indented.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return unquoted(trimmed(rest))
    }

    private static func fields(_ block: [String]) -> [Field] {
        // A nil value waits for the line after its key to give its kind.
        var fields: [(key: String, value: Value?)] = []
        for line in block where !isBlank(line) {
            if let (key, rest) = key(of: line) {
                fields.append((key, value(trimmed(rest))))
                continue
            }
            guard let last = fields.indices.last else { continue }
            let item = item(of: line)
            let text = trimmed(line)
            switch fields[last].value {
            case nil: fields[last].value = item.map { .list($0.isEmpty ? [] : [$0]) } ?? .text(text)
            case .text(let above)?: fields[last].value = .text(above.isEmpty ? text : above + "\n" + text)
            case .list(let items)?:
                let next = item ?? text
                fields[last].value = .list(next.isEmpty ? items : items + [next])
            }
        }
        return fields.map { Field(key: $0.key, value: $0.value ?? .text("")) }
    }

    /// Nil when the field's kind waits for the line after it.
    private static func value(_ rest: String) -> Value? {
        if rest.isEmpty { return nil }
        guard rest.hasPrefix("["), rest.hasSuffix("]") else { return .text(unquoted(rest)) }
        return .list(
            rest.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
                .map { unquoted(trimmed($0)) }.filter { !$0.isEmpty })
    }

    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count > 1, let first = text.first, first == text.last, first == "\"" || first == "'" else {
            return text
        }
        return String(text.dropFirst().dropLast())
    }
}
