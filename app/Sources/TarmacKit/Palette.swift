/// Every colour of a theme, as `0xRRGGBB` in sRGB (specs 2610.0007,
/// 2610.0008): the one home of the values, so that a test can see them.
///
/// There is no terminal-body token: the body of a terminal card and the `pre`
/// of a doc page take `terminal.background`.
public struct Palette: Equatable, Sendable {
    public struct Terminal: Equatable, Sendable {
        public let foreground, background, cursor, selection: UInt32
        public let selectionAlpha: Double
        /// The 16 ANSI colours.
        public let ansi: [UInt32]
    }

    public let bg0, bg1, bg2, bg3, line, lineSoft, liftBorder, primeHeaderBg: UInt32
    public let text, muted, faint, prose: UInt32
    public let agent, amber, ok, consoleError: UInt32
    public let scrollThumb, scrollThumbLine: UInt32
    /// The four colours `repo_color_index` chooses from.
    public let repoColors: [UInt32]
    public let terminal: Terminal

    /// The appearance the palette is for, by the rule of `TerminalTheme.isDark`.
    public var variant: ThemeVariant {
        Self.variant(background: terminal.background, foreground: terminal.foreground)
    }

    static func variant(background: UInt32, foreground: UInt32) -> ThemeVariant {
        Contrast.luminance(background) < Contrast.luminance(foreground) ? .dark : .light
    }

    /// Ghostty Breeze: the look before there was a choice.
    static let breezeDark = Palette(
        bg0: 0x24282c, bg1: 0x2b3036, bg2: 0x353b41, bg3: 0x3e444b,
        line: 0x474e55, lineSoft: 0x3d434a, liftBorder: 0x5a626a, primeHeaderBg: 0x3a4046,
        text: 0xeff0f1, muted: 0xb9bfc4, faint: 0x7f8c8d, prose: 0xced3d7,
        agent: 0x1abc9c, amber: 0xfdbc4b, ok: 0x1cdc9a, consoleError: 0xf28b82,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xf67400, 0x11d116, 0x1d99f3, 0x9b59b6],
        terminal: Terminal(
            foreground: 0xced2d6, background: 0x31363b, cursor: 0xeff0f1, selection: 0x1abc9c, selectionAlpha: 0.3,
            ansi: [
                0x232627, 0xed1515, 0x11d116, 0xf67400, 0x1d99f3, 0x9b59b6, 0x1abc9c, 0xfcfcfc,
                0x7f8c8d, 0xc0392b, 0x1cdc9a, 0xfdbc4b, 0x3daee9, 0x8e44ad, 0x16a085, 0xffffff,
            ]
        )
    )

    /// No light Breeze terminal palette exists upstream, so part of this is
    /// Tarmac's own. ANSI 7 and 15 are dark greys, so that text a program
    /// prints in white can be read; the scroll thumb is the dark theme's.
    static let breezeLight = Palette(
        bg0: 0xe3e5e7, bg1: 0xeff0f1, bg2: 0xdee0e2, bg3: 0xcdd1d5,
        line: 0xb4b9be, lineSoft: 0xc9cdd1, liftBorder: 0x8e959c, primeHeaderBg: 0xd0d4d8,
        text: 0x232629, muted: 0x535d66, faint: 0x707d8a, prose: 0x31363b,
        agent: 0x12846e, amber: 0xa36802, ok: 0x176839, consoleError: 0xda4453,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xbe5a00, 0x0b8a0f, 0x2980b9, 0x9b59b6],
        terminal: Terminal(
            foreground: 0x232629, background: 0xfcfcfc, cursor: 0x232629, selection: 0x12846e, selectionAlpha: 0.3,
            ansi: [
                0x232627, 0xed1515, 0x0b8a0f, 0xbe5a00, 0x2980b9, 0x9b59b6, 0x12846e, 0x63686d,
                0x7f8c8d, 0xc0392b, 0x11865e, 0xa36802, 0x147db3, 0x8e44ad, 0x16a085, 0x232629,
            ]
        )
    )

    /// The six below (spec 2610.0008): the terminal colours are the upstream
    /// values, kept as they are; the chrome is the theme's own design tokens
    /// where one fits, and is held to the floors of `PaletteCheck`.
    static let catppuccinLatte = Palette(
        bg0: 0xdce0e8, bg1: 0xe6e9ef, bg2: 0xccd0da, bg3: 0xbcc0cc,
        line: 0xacb0be, lineSoft: 0xbcc0cc, liftBorder: 0x8c8fa1, primeHeaderBg: 0xc4c8d3,
        text: 0x4c4f69, muted: 0x55586e, faint: 0x7c7f93, prose: 0x4c4f69,
        agent: 0x148187, amber: 0xa26715, ok: 0x358423, consoleError: 0xd20f39,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xc84a01, 0x358423, 0x1e66f5, 0x8839ef],
        terminal: Terminal(
            foreground: 0x4c4f69, background: 0xeff1f5, cursor: 0xdc8a78, selection: 0x148187, selectionAlpha: 0.3,
            ansi: [
                0xbcc0cc, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0x5c5f77,
                0xacb0be, 0xe7103f, 0x46b02f, 0xe49931, 0x3878f6, 0xef95d7, 0x19a1a8, 0x6c6f85,
            ]
        )
    )

    static let catppuccinMocha = Palette(
        bg0: 0x11111b, bg1: 0x181825, bg2: 0x313244, bg3: 0x45475a,
        line: 0x585b70, lineSoft: 0x45475a, liftBorder: 0x6c7086, primeHeaderBg: 0x3b3c4f,
        text: 0xcdd6f4, muted: 0xa6adc8, faint: 0x7f849c, prose: 0xbac2de,
        agent: 0x94e2d5, amber: 0xf9e2af, ok: 0xa6e3a1, consoleError: 0xf38ba8,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xfab387, 0xa6e3a1, 0x89b4fa, 0xcba6f7],
        terminal: Terminal(
            foreground: 0xcdd6f4, background: 0x1e1e2e, cursor: 0xf5e0dc, selection: 0x94e2d5, selectionAlpha: 0.3,
            ansi: [
                0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                0x585b70, 0xf7aec2, 0xc2ecbf, 0xfcd682, 0xaeccfc, 0xf398da, 0xb1eae1, 0xa6adc8,
            ]
        )
    )

    static let githubLight = Palette(
        bg0: 0xeaeef2, bg1: 0xf6f8fa, bg2: 0xe1e6eb, bg3: 0xd0d7de,
        line: 0xafb8c1, lineSoft: 0xd0d7de, liftBorder: 0x8c959f, primeHeaderBg: 0xd8dee4,
        text: 0x1f2328, muted: 0x5f676f, faint: 0x6e7781, prose: 0x24292f,
        agent: 0x1b7c83, amber: 0x9a6700, ok: 0x1a7f37, consoleError: 0xd1242f,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xbc4c00, 0x1a7f37, 0x0969da, 0x8250df],
        terminal: Terminal(
            foreground: 0x1f2328, background: 0xffffff, cursor: 0x0969da, selection: 0x1b7c83, selectionAlpha: 0.3,
            ansi: [
                0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
                0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
            ]
        )
    )

    static let githubDark = Palette(
        bg0: 0x010409, bg1: 0x070a10, bg2: 0x161b22, bg3: 0x21262d,
        line: 0x30363d, lineSoft: 0x21262d, liftBorder: 0x484f58, primeHeaderBg: 0x1c2028,
        text: 0xe6edf3, muted: 0x848d97, faint: 0x6e7681, prose: 0xc9d1d9,
        agent: 0x39c5cf, amber: 0xd29922, ok: 0x3fb950, consoleError: 0xf85149,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xdb6d28, 0x3fb950, 0x2f81f7, 0xa371f7],
        terminal: Terminal(
            foreground: 0xe6edf3, background: 0x0d1117, cursor: 0x2f81f7, selection: 0x39c5cf, selectionAlpha: 0.3,
            ansi: [
                0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
                0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff,
            ]
        )
    )

    static let solarizedLight = Palette(
        bg0: 0xeee8d5, bg1: 0xf6efdc, bg2: 0xe5e1cf, bg3: 0xd9d7c8,
        line: 0xc1c3b8, lineSoft: 0xd4d3c5, liftBorder: 0x93a1a1, primeHeaderBg: 0xdedbca,
        text: 0x073642, muted: 0x53676e, faint: 0x839496, prose: 0x586e75,
        agent: 0x258d85, amber: 0xa17a00, ok: 0x758700, consoleError: 0xdc322f,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xcb4b16, 0x758700, 0x2485c9, 0x6c71c4],
        terminal: Terminal(
            foreground: 0x657b83, background: 0xfdf6e3, cursor: 0x657b83, selection: 0x258d85, selectionAlpha: 0.3,
            ansi: [
                0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xbbb5a2,
                0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
            ]
        )
    )

    static let solarizedDark = Palette(
        bg0: 0x001e26, bg1: 0x00252e, bg2: 0x073642, bg3: 0x16404b,
        line: 0x264b55, lineSoft: 0x16404b, liftBorder: 0x586e75, primeHeaderBg: 0x0f3c47,
        text: 0xeee8d5, muted: 0x93a1a1, faint: 0x586e75, prose: 0x839496,
        agent: 0x2aa198, amber: 0xb58900, ok: 0x859900, consoleError: 0xde3f3c,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xd44e17, 0x859900, 0x268bd2, 0x6e73c5],
        terminal: Terminal(
            foreground: 0x839496, background: 0x002b36, cursor: 0x839496, selection: 0x2aa198, selectionAlpha: 0.3,
            ansi: [
                0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                0x335e69, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
            ]
        )
    )
}
