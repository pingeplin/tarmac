import AppKit

// Tokens from docs/v4/visual-crib.md §2 (Ghostty Breeze; authored sRGB hex).
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
    static let liftBorder = srgb(0x5a626a)
    static let amber = srgb(0xfdbc4b)
    static let ok = srgb(0x1cdc9a)

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
