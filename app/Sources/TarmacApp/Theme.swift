import AppKit

// Tokens from docs/m0/visual-crib.md (sRGB; oklch values pre-converted there).
@MainActor
enum Theme {
    static let bg0 = srgb(0x0c0e12)
    static let bg1 = srgb(0x12151a)
    static let bg2 = srgb(0x191d24)
    static let bg3 = srgb(0x20252e)
    static let termBg = srgb(0x0a0c10)
    static let line = srgb(0x262c36)
    static let lineSoft = srgb(0x1d222b)
    static let text = srgb(0xd8dbe2)
    static let muted = srgb(0x8c93a0)
    static let faint = srgb(0x5a616d)
    static let agent = srgb(0x4eccd3)
    static let amber = srgb(0xe1ad63)
    static let ok = srgb(0x7fc08c)

    static let repoColors: [NSColor] = [
        srgb(0xd78e88), // repo-a
        srgb(0x81b482), // repo-b
        srgb(0x89a4de), // repo-c
        srgb(0xbe92c8), // repo-d
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
