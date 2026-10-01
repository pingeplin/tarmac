import Foundation

/// A JSON tree with JavaScript's number semantics: one `Double` type for every
/// number, so a snapshot's `1` equals an expression's `1`. It carries the
/// payloads the app reads from untrusted or foreign JSON — console args relayed
/// from an HTML card, the QA driver's snapshot — where `[Any]` could be neither
/// `Equatable` nor `Sendable`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Bridges what Foundation hands over — a `WKScriptMessage` body or
    /// `JSONSerialization` output. Nil for any value JSON cannot carry (a `Date`,
    /// a custom object) anywhere in the tree.
    public init?(foundation value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // An NSNumber 1 and the Boolean true both bridge to `Bool`; only the CF type tells them apart.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            var items: [JSONValue] = []
            for element in array {
                guard let item = JSONValue(foundation: element) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            var fields: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                guard let field = JSONValue(foundation: element) else { return nil }
                fields[key] = field
            }
            self = .object(fields)
        default:
            return nil
        }
    }

    /// Compact JSON text like `JSON.stringify`, except object keys are sorted — a
    /// `Dictionary` keeps no insertion order. A non-finite number is `null`, as
    /// `JSON.stringify` writes it.
    public var jsonString: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value.isFinite ? Self.numberText(value) : "null"
        case .string(let value): Self.quoted(value)
        case .array(let items): "[" + items.map(\.jsonString).joined(separator: ",") + "]"
        case .object(let fields):
            "{" + fields.sorted { $0.key < $1.key }
                .map { "\(Self.quoted($0.key)):\($0.value.jsonString)" }
                .joined(separator: ",") + "}"
        }
    }

    /// One display form per value, as a console line shows it: a scalar as
    /// JavaScript's `String(value)` — strings bare — and an array or object as
    /// JSON, never an opaque placeholder.
    public var displayString: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): Self.numberText(value)
        case .string(let value): value
        case .array, .object: jsonString
        }
    }

    /// JavaScript's `String(number)`. Integers print exactly up to 2^53, where every
    /// integer is representable; larger or fractional values use Swift's shortest
    /// round-trip form, which agrees with JavaScript's except in how it writes
    /// very large and very small exponents.
    private static func numberText(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
