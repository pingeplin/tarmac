/// What a doc card is given for its fonts: each chosen family as a CSS
/// string before the stack the role falls back to (spec 2610.0005), and the
/// prose size as a length (spec 2610.0006).
public enum FontCSS {
    /// `ui-monospace` is the only name WebKit resolves to the system
    /// monospaced face.
    public static let monospaceStack = "ui-monospace, monospace"
    public static let proseStack = #"-apple-system, "SF Pro Text", system-ui, sans-serif"#

    public static func interface(_ family: String?) -> String { stack(family, before: monospaceStack) }

    public static func document(_ family: String?) -> String { stack(family, before: proseStack) }

    public static func proseSize(_ size: Double) -> String { FontSizeRule.text(size) + "px" }

    private static func stack(_ family: String?, before fallback: String) -> String {
        guard let family, FontRole.isFamilyName(family) else { return fallback }
        // A JSON string is a CSS string for a name with no control character,
        // which `isFamilyName` has just refused.
        return "\(JSONValue.string(family).jsonString), \(fallback)"
    }
}
