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

    /// How deep arrays and objects may nest when bridged from Foundation. The
    /// payloads come from an untrusted page, and walking them — or later
    /// releasing them — recurses once per level, so an unbounded depth overflows
    /// the stack. No console payload needs a tenth of this.
    public static let maxDepth = 64

    /// Bridges what Foundation hands over — a `WKScriptMessage` body or
    /// `JSONSerialization` output. Nil for any value JSON cannot carry (a `Date`,
    /// a custom object) anywhere in the tree, and for nesting past `maxDepth`.
    public init?(foundation value: Any) {
        self.init(foundation: value, containerDepth: 0)
    }

    private init?(foundation value: Any, containerDepth: Int) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // An NSNumber 1 and the Boolean true both bridge to `Bool`; only the CF type tells them apart.
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]:
            guard containerDepth < Self.maxDepth else { return nil }
            var items: [JSONValue] = []
            for element in array {
                guard let item = JSONValue(foundation: element, containerDepth: containerDepth + 1) else { return nil }
                items.append(item)
            }
            self = .array(items)
        case let dictionary as [String: Any]:
            guard containerDepth < Self.maxDepth else { return nil }
            var fields: [String: JSONValue] = [:]
            for (key, element) in dictionary {
                guard let field = JSONValue(foundation: element, containerDepth: containerDepth + 1) else { return nil }
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

    /// JavaScript's `String(number)` (ECMAScript Number::toString): the shortest
    /// round-trip digits, written out in full from 10^-6 up to 10^21 and in
    /// exponent form beyond. Swift's `description` has the same digits but switches
    /// layout earlier and pads exponents to two digits, so only its digits are used.
    private static func numberText(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }
        if value < 0 { return "-" + numberText(-value) }
        if value.isInfinite { return "Infinity" }

        // value = 0.<digits> × 10^point
        let (digits, point) = shortestDigits(value)
        let count = digits.count
        if count <= point, point <= 21 { return digits + String(repeating: "0", count: point - count) }
        if 0 < point, point <= 21 { return String(digits.prefix(point)) + "." + String(digits.dropFirst(point)) }
        if -6 < point, point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
        let exponent = point - 1
        let tail = "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        return count == 1 ? digits + tail : String(digits.prefix(1)) + "." + String(digits.dropFirst()) + tail
    }

    /// The shortest round-trip digits of a positive finite `value`, without leading
    /// or trailing zeros, and the decimal point position they sit at.
    private static func shortestDigits(_ value: Double) -> (digits: String, point: Int) {
        let text = "\(value)"
        let parts = text.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = mantissa[0]
        let fractionPart = mantissa.count > 1 ? mantissa[1] : ""
        var digits = Substring(integerPart + fractionPart)
        var point = integerPart.count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.count > 1, digits.first == "0" {
            digits = digits.dropFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits = digits.dropLast() }
        return (String(digits), point)
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
