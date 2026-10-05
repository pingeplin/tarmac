import AppKit
import TarmacKit

// Tokens from docs/archive/v4/visual-crib.md §2 (Ghostty Breeze; authored sRGB hex).
@MainActor
enum Theme {
    static let bg0 = srgb(0x24282c)
    static let bg1 = srgb(0x2b3036)
    static let bg2 = srgb(0x353b41)
    static let bg3 = srgb(0x3e444b)
    static let termBg = srgb(0x31363b)
    static let line = srgb(0x474e55)
    static let lineSoft = srgb(0x3d434a)
    static let text = srgb(0xeff0f1)
    static let muted = srgb(0xb9bfc4)
    static let faint = srgb(0x7f8c8d)
    static let agent = srgb(0x1abc9c)
    static let agentDim = srgb(0x1abc9c, alpha: 0.16)
    // Drag-lift border (crib §4 prime/lift; authored hex, not a :root token).
    static let liftBorder = srgb(0x5a626a)
    // The scroll thumb: dark with a light hairline, and opaque, so it is the
    // same thumb on a terminal, on the doc page and on a white HTML document.
    static let scrollThumb = srgb(0x181b1d)
    static let scrollThumbLine = srgb(0x696b6c)
    // The selected card's border: the card whose body takes the wheel.
    static let focusBorder = srgb(0x1abc9c, alpha: 0.5)
    // Prime-card header bg (crib §1/§2/§4: `.tm-bcard.prime .bhd` background
    // `#3a4046` — near bg2 but distinct). New Breeze token Theme.swift lacked.
    static let primeHeaderBg = srgb(0x3a4046)
    static let amber = srgb(0xfdbc4b)
    static let ok = srgb(0x1cdc9a)

    /// Terminal interior font size in world points (crib §3). The board zoom
    /// scales each card as a single unit, so this is the on-screen size at 100%.
    static let termFontSize: CGFloat = 16

    static let repoColors: [NSColor] = [
        srgb(0xf67400), // repo-a — orange
        srgb(0x11d116), // repo-b — green
        srgb(0x1d99f3), // repo-c — blue
        srgb(0x9b59b6), // repo-d — purple
    ]

    /// The family in effect for each role, as `FontSettings` last resolved
    /// it; no entry is the system default.
    static var fontFamilies: [FontRole: String] = [:]

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

    private static func srgb(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha
        )
    }
}
