import Foundation

/// A markdown doc's front matter (spec 2611.0022, D1–D3): the fields a block
/// between two fences at the doc's top holds, and the body after it. Not a
/// YAML parser: a line it does not know joins the field above it as text.
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
        let lines = markdown.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let text = lines.map { line in
            let line = String(Substring(line))
            return line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
        guard text.count > 1, isFence(text[0], marks: ["---"]),
              let close = text.indices.dropFirst().first(where: { isFence(text[$0], marks: ["---", "..."]) })
        else { return ([], markdown) }
        let block = text[1..<close]
        guard block.contains(where: { key(of: $0) != nil }), block.allSatisfy(isAllowed) else { return ([], markdown) }

        let end = lines[close].endIndex
        let body = end == markdown.utf8.endIndex ? "" : String(markdown[markdown.utf8.index(after: end)...])
        return (fields(block), body)
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
              first == "_" || isLetterOrDigit(first) else { return nil }
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

    private static func fields(_ block: ArraySlice<String>) -> [Field] {
        var keys: [String] = []
        var values: [Value?] = []
        for line in block where !isBlank(line) {
            if let (key, rest) = key(of: line) {
                keys.append(key)
                values.append(value(trimmed(rest)))
                continue
            }
            guard let last = values.indices.last else { continue }
            let item = item(of: line)
            switch values[last] {
            case nil: values[last] = item.map { .list($0.isEmpty ? [] : [$0]) } ?? .text(trimmed(line))
            case .text(let text)?: values[last] = .text(text.isEmpty ? trimmed(line) : text + "\n" + trimmed(line))
            case .list(let items)?:
                let next = item ?? trimmed(line)
                values[last] = .list(next.isEmpty ? items : items + [next])
            }
        }
        return zip(keys, values).map { Field(key: $0, value: $1 ?? .text("")) }
    }

    /// Nil when the field's kind waits for the line after it.
    private static func value(_ rest: String) -> Value? {
        if rest.isEmpty { return nil }
        guard rest.hasPrefix("["), rest.hasSuffix("]"), rest.count > 1 else { return .text(unquoted(rest)) }
        return .list(rest.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
            .map { unquoted(trimmed($0)) }.filter { !$0.isEmpty })
    }

    private static func trimmed(_ text: some StringProtocol) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count > 1, let first = text.first, first == text.last, first == "\"" || first == "'" else { return text }
        return String(text.dropFirst().dropLast())
    }
}
