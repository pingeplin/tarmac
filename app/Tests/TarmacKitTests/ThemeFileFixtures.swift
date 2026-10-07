import Foundation
@testable import TarmacKit

/// The theme files the suites of spec 2610.0009 read: their text is here, so
/// no test reads a Ghostty install or the user's config directory.
enum ThemeFixture {
    /// The Dracula file of Ghostty 1.3.1.
    static let dracula = """
        palette = 0=#21222c
        palette = 1=#ff5555
        palette = 2=#50fa7b
        palette = 3=#f1fa8c
        palette = 4=#bd93f9
        palette = 5=#ff79c6
        palette = 6=#8be9fd
        palette = 7=#f8f8f2
        palette = 8=#6272a4
        palette = 9=#ff6e6e
        palette = 10=#69ff94
        palette = 11=#ffffa5
        palette = 12=#d6acff
        palette = 13=#ff92df
        palette = 14=#a4ffff
        palette = 15=#ffffff
        background = #282a36
        foreground = #f8f8f2
        cursor-color = #f8f8f2
        cursor-text = #282a36
        selection-background = #44475a
        selection-foreground = #ffffff

        """

    static let draculaANSI: [UInt32] = [
        0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
        0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
    ]

    static let draculaColours = colours(
        background: 0x282a36, foreground: 0xf8f8f2, cursor: 0xf8f8f2, ansi: draculaANSI
    )

    /// The Catppuccin Latte file of Ghostty 1.3.1.
    static let latteColours = colours(
        background: 0xeff1f5, foreground: 0x4c4f69, cursor: 0xdc8a78,
        ansi: [
            0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
            0x6c6f85, 0xde293e, 0x49af3d, 0xeea02d, 0x456eff, 0xfe85d8, 0x2d9fa8, 0xbcc0cc,
        ]
    )

    static let hotDogStandColours = colours(
        background: 0xea3323, foreground: 0xffffff, cursor: 0xffff54,
        ansi: [
            0x000000, 0xffff54, 0xffff54, 0xffff54, 0x000000, 0xffff54, 0xffffff, 0xc6c6c6,
            0x000000, 0xffff54, 0xffff54, 0xffff54, 0x000000, 0xffff54, 0xffffff, 0xc6c6c6,
        ]
    )

    static let black = colours(background: 0x000000, foreground: 0xffffff)
    static let white = colours(background: 0xffffff, foreground: 0x000000)

    static func colours(
        background: UInt32, foreground: UInt32, cursor: UInt32? = nil, ansi: [UInt32] = [],
        chrome: [ThemeFile.ChromeKey: UInt32] = [:], repo: [Int: UInt32] = [:]
    ) -> ThemeFile.Colours {
        ThemeFile.Colours(
            background: background, foreground: foreground, cursor: cursor,
            ansi: Dictionary(uniqueKeysWithValues: ansi.enumerated().map { ($0.offset, $0.element) }),
            chrome: chrome, repo: repo
        )
    }

    /// A text with a valid background and foreground as its lines 1 and 2,
    /// and then `lines`.
    static func text(_ lines: String...) -> String {
        (["background = #000000", "foreground = #ffffff"] + lines).joined(separator: "\n")
    }
}
