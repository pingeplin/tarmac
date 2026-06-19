import AppKit

// Tokens from docs/archive/v4/visual-crib.md §2 (Ghostty Breeze; authored sRGB hex).
@MainActor
enum Theme {
    static let bg0 = srgb(0x24282c)
    static let bg1 = srgb(0x2b3036)
    static let bg2 = srgb(0x353b41)
    static let bg3 = srgb(0x3e444b)
    static let termBg = srgb(0x31363b)
    // Terminal-interior default fg (crib §3; scoped Breeze muted, NOT chrome muted).
    static let termFg = srgb(0xced2d6)
    static let line = srgb(0x474e55)
    static let lineSoft = srgb(0x3d434a)
    static let text = srgb(0xeff0f1)
    static let muted = srgb(0xb9bfc4)
    static let faint = srgb(0x7f8c8d)
    static let agent = srgb(0x1abc9c)
    static let agentDim = srgb(0x1abc9c, alpha: 0.16)
    // Drag-lift border (crib §4 prime/lift; authored hex, not a :root token).
    // Reused as the prime-card border and the cockpit dock-pane top border.
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
    // Amber tint (crib §1/§7): locard bell ring, conflict banner. New Breeze
    // token Theme.swift lacked; mirrors agentDim's construction.
    static let amberDim = srgb(0xfdbc4b, alpha: 0.16)
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

    /// IBM Plex Mono else SF Mono (else Menlo, unreachable: monospacedSystemFont
    /// always resolves).
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let plexName: String
        switch weight {
        case .medium: plexName = "IBMPlexMono-Medium"
        case .semibold: plexName = "IBMPlexMono-SemiBold"
        default: plexName = "IBMPlexMono"
        }
        return NSFont(name: plexName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Terminal-card interior face (crib §3): JetBrainsMono Nerd Font Mono if
    /// installed, else the chrome `mono` stack (IBM Plex Mono → SF Mono). Scoped
    /// to terminal cards so shell prompts render Nerd Font powerline/icon glyphs;
    /// the chrome keeps `mono`. The "Mono" (NFM) spacing variant forces icon
    /// glyphs to a single cell so they don't overflow SwiftTerm's character grid
    /// — the variant Nerd Fonts recommends for terminals. Like `mono`, this is
    /// name resolution against a system-installed font — NOT bundled, so it
    /// degrades gracefully when absent. PostScript names per
    /// `system_profiler SPFontsDataType`.
    static func termFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let nerdName: String
        switch weight {
        case .medium: nerdName = "JetBrainsMonoNFM-Medium"
        case .semibold: nerdName = "JetBrainsMonoNFM-SemiBold"
        default: nerdName = "JetBrainsMonoNFM-Regular"
        }
        return NSFont(name: nerdName, size: size) ?? mono(size, weight: weight)
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
