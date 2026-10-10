import AppKit
import TarmacKit

/// The colours of the theme in effect (spec 2610.0007), and the fonts. A
/// colour is read from `palette` each time it is asked for, so a view that
/// keeps one takes it again when the theme changes (`ThemeFollowing`).
@MainActor
enum Theme {
    /// The theme in effect, as `ThemeSettings` last resolved it.
    static var entry = ThemeCatalog.standard(for: .dark)

    static var palette: Palette { entry.palette }

    static var bg0: NSColor { srgb(palette.bg0) }
    static var bg1: NSColor { srgb(palette.bg1) }
    static var bg2: NSColor { srgb(palette.bg2) }
    static var bg3: NSColor { srgb(palette.bg3) }
    static var termBg: NSColor { srgb(palette.terminal.background) }
    static var line: NSColor { srgb(palette.line) }
    static var lineSoft: NSColor { srgb(palette.lineSoft) }
    static var text: NSColor { srgb(palette.text) }
    static var muted: NSColor { srgb(palette.muted) }
    static var faint: NSColor { srgb(palette.faint) }
    static var agent: NSColor { srgb(palette.agent) }
    static var agentDim: NSColor { srgb(palette.agent, alpha: 0.16) }
    static var liftBorder: NSColor { srgb(palette.liftBorder) }
    // The scroll thumb: dark with a light hairline in every theme, and
    // opaque, so it is the same thumb on a terminal, on the doc page and on a
    // white HTML document.
    static var scrollThumb: NSColor { srgb(palette.scrollThumb) }
    static var scrollThumbLine: NSColor { srgb(palette.scrollThumbLine) }
    // The selected card's border: the card whose body takes the wheel.
    static var focusBorder: NSColor { srgb(palette.agent, alpha: 0.5) }
    static var primeHeaderBg: NSColor { srgb(palette.primeHeaderBg) }
    static var amber: NSColor { srgb(palette.amber) }
    static var ok: NSColor { srgb(palette.ok) }
    static var consoleError: NSColor { srgb(palette.consoleError) }

    /// One colour for each index `RepoDot.paletteIndex` gives.
    static var repoColors: [NSColor] { palette.repoColors.map { srgb($0) } }

    /// The family in effect for each role, as `FontSettings` last resolved
    /// it; no entry is the system default.
    static var fontFamilies: [FontRole: String] = [:]

    /// The size in effect for each role that has one, as `FontSettings` last
    /// resolved it.
    static var fontSizes: [FontRole: Double] = [:]

    /// In world points: the board zoom scales each card as a single unit, so
    /// this is the on-screen size at 100%.
    static var terminalFontSize: CGFloat { fontSizes[.terminal] ?? FontSizeRule.terminal.standard }

    static var proseFontSize: Double { fontSizes[.document] ?? FontSizeRule.document.standard }

    /// What an HTML card is given for the fonts in effect.
    static var cardFonts: CardFontVariables {
        CardFontVariables(
            interfaceFamily: fontFamilies[.interface], documentFamily: fontFamilies[.document],
            documentSize: proseFontSize
        )
    }

    /// The chrome face: the Interface family, or the system's monospaced
    /// font. A family has a regular and at most a bold, so a weight takes the
    /// nearer of the two, and a family with no bold gives its regular face.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
        return chosen(.interface, size: size, bold: bold) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The regular face a role's text is set in, for the Settings window's
    /// sample line.
    static func sample(_ role: FontRole) -> NSFont {
        let size = NSFont.systemFontSize
        return chosen(role, size: size)
            ?? (role.fixedPitchOnly ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size))
    }

    private static func chosen(_ role: FontRole, size: CGFloat, bold: Bool = false) -> NSFont? {
        fontFamilies[role].flatMap { InstalledFonts.face(of: $0, bold: bold, size: size) }
    }

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func srgb(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha
        )
    }
}
