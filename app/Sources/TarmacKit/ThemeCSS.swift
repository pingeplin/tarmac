import Foundation

/// What a page is given for its colours (spec 2610.0007): the declarations of
/// a theme, and a page template with them in place. A hidden page does not
/// restyle itself from a media query, so the values are pushed, and they have
/// this one source.
public enum ThemeCSS {
    public static let marker = "/*tarmac-theme*/"
    public static let backdropMarker = "/*tarmac-backdrop*/"

    private static let backdrop = "--bg1"

    /// The declarations, in the order they are written.
    public static func properties(_ variant: ThemeVariant) -> [(name: String, value: String)] {
        let palette = Palette.of(variant)
        return [
            (backdrop, hex(palette.bg1)),
            ("--bg2", hex(palette.bg2)),
            ("--term-bg", hex(palette.terminal.background)),
            ("--text", hex(palette.text)),
            ("--prose-text", hex(palette.prose)),
            ("--agent", hex(palette.agent)),
            ("--agent-dim", rgba(palette.agent, alpha: "0.16")),
            ("color-scheme", variant.rawValue),
        ]
    }

    /// `template` with `marker` replaced by every declaration, and
    /// `backdropMarker` by the `--bg1` declaration alone.
    public static func page(_ template: String, _ variant: ThemeVariant) -> String {
        let all = properties(variant)
        return put(all.filter { $0.name == backdrop }, at: backdropMarker, in: put(all, at: marker, in: template))
    }

    /// A marker is a place only when the template holds it exactly once.
    private static func put(
        _ declarations: [(name: String, value: String)], at marker: String, in template: String
    ) -> String {
        let around = template.components(separatedBy: marker)
        guard around.count == 2 else { return template }
        return around.joined(separator: declarations.map { "\($0.name): \($0.value);" }.joined(separator: " "))
    }

    private static func hex(_ rgb: UInt32) -> String { String(format: "#%06x", rgb) }

    private static func rgba(_ rgb: UInt32, alpha: String) -> String {
        "rgba(\(rgb >> 16 & 0xff), \(rgb >> 8 & 0xff), \(rgb & 0xff), \(alpha))"
    }
}
