import AppKit

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
    // Scroll-focus border: the quiet sibling of `liftBorder`. A focused card (the
    // pointer/scroll-active card — `focusedCardID`, incl. doc cards) wears this
    // soft teal edge so scroll-capture is legible. Deliberately a different hue
    // family from prime's neutral gray: when keyboard-active (prime, gray border +
    // dark header) and scroll-active (focus, teal edge) are two different cards,
    // the colors tell them apart at a glance. Sits below prime in the border stack.
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

    static func repoColor(for name: String) -> NSColor {
        // FNV-1a: stable across launches (hashValue is seeded per-process).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return repoColors[Int(hash % UInt64(repoColors.count))]
    }

    /// Daemon-assigned index wins; the local hash is the repo==nil fallback
    /// (same algorithm, per docs/protocol.md "repo_color").
    static func repoColor(index: Int?, fallbackName: String) -> NSColor {
        if let index, repoColors.indices.contains(index) {
            return repoColors[index]
        }
        return repoColor(for: fallbackName)
    }

    /// The chrome face: IBM Plex Mono, bundled in regular and bold only, so a
    /// weight takes the nearer of the two; the system's monospaced font if the
    /// bundled faces did not register.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let face = weight.rawValue >= NSFont.Weight.semibold.rawValue ? "IBMPlexMono-Bold" : "IBMPlexMono-Regular"
        return NSFont(name: face, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
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
