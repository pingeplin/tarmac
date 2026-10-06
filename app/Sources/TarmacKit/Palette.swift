/// Every colour of a theme, as `0xRRGGBB` in sRGB (spec 2610.0007): the one
/// home of the values, so that a test can see them.
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

    public static func of(_ variant: ThemeVariant) -> Palette {
        switch variant {
        case .light: breezeLight
        case .dark: breezeDark
        }
    }

    /// Ghostty Breeze: the look before there was a choice.
    private static let breezeDark = Palette(
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
    private static let breezeLight = Palette(
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
}
