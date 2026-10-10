import Foundation

/// What an HTML card is given for the user's fonts (spec 2610.0010): three CSS
/// custom properties on its root, with the values `FontCSS` gives a doc card.
/// The names have this one owner; the shim takes any `--tarmac-` name.
public struct CardFontVariables: Equatable, Sendable {
    public static let proseSize = "--tarmac-prose-size"
    public static let proseFont = "--tarmac-prose-font"
    public static let monoFont = "--tarmac-mono-font"
    /// Where the shim holds the values, as `[/*tarmac-fonts*/][0]`: a comment
    /// keeps the file valid JavaScript before it is filled.
    public static let marker = "/*tarmac-fonts*/"

    private let values: [String: JSONValue]

    public init(interfaceFamily: String?, documentFamily: String?, documentSize: Double) {
        values = [
            Self.monoFont: .string(FontCSS.interface(interfaceFamily)),
            Self.proseFont: .string(FontCSS.document(documentFamily)),
            Self.proseSize: .string(FontCSS.proseSize(documentSize)),
        ]
    }

    /// The values as a JSON object and a JavaScript literal, safe in an HTML
    /// `<script>` and in a script the app evaluates. A family name is the
    /// user's text: `<` would let `</script>` end the element, and U+2028 and
    /// U+2029 end a line in older JavaScript. None can sit in an escape
    /// sequence, so each is escaped where it stands.
    public var json: String {
        JSONValue.object(values).jsonString.unicodeScalars.reduce(into: "") { text, scalar in
            switch scalar.value {
            case 0x3c, 0x2028, 0x2029: text += String(format: "\\u%04x", scalar.value)
            default: text.unicodeScalars.append(scalar)
            }
        }
    }

    /// `shim` with the marker replaced by the values, when it holds the marker
    /// exactly once (as `ThemeCSS.put` does).
    public func filling(_ shim: String) -> String {
        let around = shim.components(separatedBy: Self.marker)
        guard around.count == 2 else { return shim }
        return around.joined(separator: json)
    }
}
