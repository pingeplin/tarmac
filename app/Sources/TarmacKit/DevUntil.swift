import Foundation

/// `tarmac dev snapshot --until <expr>` (spec 2609.0015, #166): a tiny,
/// hand-written predicate over a snapshot. Hand-written rather than backed by an
/// expression engine because the driver executes UI actions on request and must
/// never execute a caller's code — and because the grammar is deliberately
/// smaller than anything a general engine would give.
///
///     <path> <op> <value>
///     op     == | != | ~= (numeric, |Δ| ≤ 1) | contains
///     path   dotted; `cards[<id>]` indexes by card id, where the id runs to the
///            LAST `]` in the remainder — doc paths contain dots and slashes and
///            may contain a `]`, and none of them may be treated as syntax
///     value  number | "string" (\" and \\) | null | true | false
///
/// Two failure modes must stay distinguishable:
/// - an UNRESOLVABLE path evaluates to false, in both polarities, so a card that
///   has not rendered yet keeps the poll going rather than failing the run;
/// - a MALFORMED expression is a parse error, so the app answers `bad_expr` at
///   once instead of spending the whole timeout on something that can never hold.
///
/// Paths descend through objects only: an array is reached through `cards[<id>]`,
/// never by a dotted index. Numbers are decimal or exponent literals. Strings are
/// equal only when their Unicode scalars are, as JavaScript's `===` has it —
/// `String ==` would equate a precomposed and a decomposed spelling of one name.
public enum DevUntil {
    /// How close `~=` counts as equal, in the value's own units.
    public static let numericTolerance = 1.0

    public enum Op: String, Equatable, Sendable {
        case equal = "=="
        case notEqual = "!="
        case approximately = "~="
        case contains
    }

    public struct Expression: Equatable, Sendable {
        public var path: String
        public var op: Op
        public var value: JSONValue

        public init(path: String, op: Op, value: JSONValue) {
            self.path = path
            self.op = op
            self.value = value
        }
    }

    public struct ParseError: Error, Equatable, Sendable {
        public var message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    public static func parse(_ source: String) throws -> Expression {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ParseError("empty expression") }

        // `contains` is a word, the rest are symbols; match the word first so a path
        // ending in "contains" cannot be mistaken for the operator.
        let rawPath: Substring, rawOp: Substring, rawValue: Substring
        if let match = text.firstMatch(of: /^(.*?)\s+(contains)\s+(.*)$/) {
            (rawPath, rawOp, rawValue) = (match.1, match.2, match.3)
        } else if let match = text.firstMatch(of: /^(.*?)\s*(==|!=|~=)\s*(.*)$/) {
            (rawPath, rawOp, rawValue) = (match.1, match.2, match.3)
        } else {
            throw ParseError("expected <path> <op> <value>, got \(JSONValue.string(source).jsonString)")
        }

        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { throw ParseError("missing path") }
        let valueText = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = parseValue(valueText), let op = Op(rawValue: String(rawOp)) else {
            throw ParseError("not a value: \(JSONValue.string(valueText).jsonString)")
        }
        return Expression(path: path, op: op, value: value)
    }

    public static func evaluate(_ expression: Expression, against snapshot: JSONValue) -> Bool {
        // An unresolvable path makes no claim, so NEITHER polarity may fire — `!=`
        // included, or a typo'd path would satisfy every `!=` immediately.
        guard let actual = resolve(snapshot, expression.path) else { return false }
        switch (expression.op, actual, expression.value) {
        case (.equal, _, _):
            return identical(actual, expression.value)
        case (.notEqual, _, _):
            return !identical(actual, expression.value)
        case (.approximately, .number(let actual), .number(let expected)):
            return abs(actual - expected) <= numericTolerance
        case (.contains, .string(let actual), .string(let needle)):
            // `range(of:)` finds no empty needle, and `.literal` compares code units
            // as `includes` does, not grapheme clusters as `String.contains` would.
            return needle.isEmpty || actual.range(of: needle, options: .literal) != nil
        default:
            return false
        }
    }

    /// `===` for the scalars an expression can name; an array or object is never
    /// identical to one.
    private static func identical(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        if case .string(let a) = lhs, case .string(let b) = rhs { return a.unicodeScalars.elementsEqual(b.unicodeScalars) }
        return lhs == rhs
    }

    private static func parseValue(_ source: String) -> JSONValue? {
        switch source {
        case "null": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        let scalars = source.unicodeScalars
        if scalars.first == "\"" {
            var text = String.UnicodeScalarView()
            var index = scalars.index(after: scalars.startIndex)
            while index < scalars.endIndex {
                let scalar = scalars[index]
                if scalar == "\\" {
                    index = scalars.index(after: index)
                    guard index < scalars.endIndex else { return nil }
                    text.append(scalars[index])
                } else if scalar == "\"" {
                    // Anything after the closing quote is trailing junk.
                    return scalars.index(after: index) == scalars.endIndex ? .string(String(text)) : nil
                } else {
                    text.append(scalar)
                }
                index = scalars.index(after: index)
            }
            return nil
        }
        // `Double("0x10")` and `Double("0x1p4")` parse, and `Double("0b11")` does not;
        // the spec grammar admits only a decimal or exponent literal.
        guard source.wholeMatch(of: /[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/) != nil,
              let number = Double(source), number.isFinite
        else { return nil }
        return .number(number)
    }

    /// A key looked up by Unicode scalars: a `Dictionary` subscript would find a
    /// decomposed key from a precomposed spelling, which JavaScript does not.
    private static func field(_ name: String, in fields: [String: JSONValue]) -> JSONValue? {
        fields.first { $0.key.unicodeScalars.elementsEqual(name.unicodeScalars) }?.value
    }

    /// Walks the path. Returns nil — never throws — for anything that does not
    /// resolve, so the caller can treat "not there" as one state. A key present
    /// with a null value resolves to `.null`, which is a value, not "not there".
    private static func resolve(_ root: JSONValue, _ path: String) -> JSONValue? {
        var node = root
        var rest = path.unicodeScalars[...]
        while !rest.isEmpty {
            guard case .object(let fields) = node else { return nil }
            if rest.starts(with: "cards[".unicodeScalars) {
                // Everything up to the LAST `]` is the literal id.
                guard let close = rest.lastIndex(of: "]") else { return nil }
                let id = String(rest[rest.index(rest.startIndex, offsetBy: 6)..<close])
                guard case .array(let cards)? = field("cards", in: fields) else { return nil }
                guard let card = cards.first(where: { card in
                    guard case .object(let cardFields) = card else { return false }
                    return field("id", in: cardFields).map { identical($0, .string(id)) } ?? false
                }) else { return nil }
                node = card
                rest = rest[rest.index(after: close)...]
                if rest.first == "." { rest = rest.dropFirst() }
                continue
            }
            let dot = rest.firstIndex(of: ".")
            let key = String(rest[..<(dot ?? rest.endIndex)])
            rest = dot.map { rest[rest.index(after: $0)...] } ?? rest[rest.endIndex...]
            guard let next = field(key, in: fields) else { return nil }
            node = next
        }
        return node
    }
}
