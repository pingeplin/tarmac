/// The `font-family` values a doc card is given (spec 2610.0005): the chosen
/// family, as a CSS string, before the stack the role falls back to.
public enum FontCSS {
    /// `ui-monospace` is the only name WebKit resolves to the system
    /// monospaced face.
    public static let monospaceStack = "ui-monospace, monospace"
    public static let proseStack = #"-apple-system, "SF Pro Text", system-ui, sans-serif"#

    public static func interface(_ family: String?) -> String { stack(family, before: monospaceStack) }

    public static func document(_ family: String?) -> String { stack(family, before: proseStack) }

    private static func stack(_ family: String?, before fallback: String) -> String {
        guard let family, FontRole.isFamilyName(family) else { return fallback }
        // A JSON string is a CSS string for a name with no control character,
        // which `isFamilyName` has just refused.
        return "\(JSONValue.string(family).jsonString), \(fallback)"
    }
}
