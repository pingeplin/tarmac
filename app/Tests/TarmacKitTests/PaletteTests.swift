import XCTest
@testable import TarmacKit

/// The colours of every theme. The expected values are the tables of the
/// specs, which are the contract for them: 2610.0007 for the two Breeze
/// palettes (its S-numbers are marked), 2610.0008 for the rest.
final class PaletteTests: XCTestCase {
    /// S7
    func testS7EveryPaletteHasFourRepoColoursAndSixteenANSIColours() {
        for entry in ThemeCatalog.all {
            XCTAssertEqual(entry.palette.repoColors.count, 4, entry.id)
            XCTAssertEqual(entry.palette.terminal.ansi.count, 16, entry.id)
        }
    }

    /// 2610.0007 S9 — the look of `289d208`, with no change.
    func testS9TheDarkPaletteIsTheLookOfToday() {
        let palette = ThemeCatalog.standard(for: .dark).palette

        XCTAssertEqual(palette.bg0, 0x24282c)
        XCTAssertEqual(palette.bg1, 0x2b3036)
        XCTAssertEqual(palette.bg2, 0x353b41)
        XCTAssertEqual(palette.bg3, 0x3e444b)
        XCTAssertEqual(palette.primeHeaderBg, 0x3a4046)
        XCTAssertEqual(palette.line, 0x474e55)
        XCTAssertEqual(palette.lineSoft, 0x3d434a)
        XCTAssertEqual(palette.liftBorder, 0x5a626a)
        XCTAssertEqual(palette.text, 0xeff0f1)
        XCTAssertEqual(palette.muted, 0xb9bfc4)
        XCTAssertEqual(palette.faint, 0x7f8c8d)
        XCTAssertEqual(palette.prose, 0xced3d7)
        XCTAssertEqual(palette.agent, 0x1abc9c)
        XCTAssertEqual(palette.amber, 0xfdbc4b)
        XCTAssertEqual(palette.ok, 0x1cdc9a)
        XCTAssertEqual(palette.consoleError, 0xf28b82)
        XCTAssertEqual(palette.scrollThumb, 0x181b1d)
        XCTAssertEqual(palette.scrollThumbLine, 0x696b6c)
        XCTAssertEqual(palette.repoColors, [0xf67400, 0x11d116, 0x1d99f3, 0x9b59b6])
    }

    /// 2610.0007 S9
    func testS9TheDarkTerminalIsBreeze() {
        let terminal = ThemeCatalog.standard(for: .dark).palette.terminal

        XCTAssertEqual(terminal.foreground, 0xced2d6)
        XCTAssertEqual(terminal.background, 0x31363b)
        XCTAssertEqual(terminal.cursor, 0xeff0f1)
        XCTAssertEqual(terminal.selection, 0x1abc9c)
        XCTAssertEqual(terminal.selectionAlpha, 0.3)
        XCTAssertEqual(terminal.ansi, [
            0x232627, 0xed1515, 0x11d116, 0xf67400, 0x1d99f3, 0x9b59b6, 0x1abc9c, 0xfcfcfc,
            0x7f8c8d, 0xc0392b, 0x1cdc9a, 0xfdbc4b, 0x3daee9, 0x8e44ad, 0x16a085, 0xffffff,
        ])
    }

    /// 2610.0007 S10
    func testS10TheLightPaletteIsBreezeLight() {
        let palette = ThemeCatalog.standard(for: .light).palette

        XCTAssertEqual(palette.bg0, 0xe3e5e7)
        XCTAssertEqual(palette.bg1, 0xeff0f1)
        XCTAssertEqual(palette.bg2, 0xdee0e2)
        XCTAssertEqual(palette.bg3, 0xcdd1d5)
        XCTAssertEqual(palette.primeHeaderBg, 0xd0d4d8)
        XCTAssertEqual(palette.line, 0xb4b9be)
        XCTAssertEqual(palette.lineSoft, 0xc9cdd1)
        XCTAssertEqual(palette.liftBorder, 0x8e959c)
        XCTAssertEqual(palette.text, 0x232629)
        XCTAssertEqual(palette.muted, 0x535d66)
        XCTAssertEqual(palette.faint, 0x707d8a)
        XCTAssertEqual(palette.prose, 0x31363b)
        XCTAssertEqual(palette.agent, 0x12846e)
        XCTAssertEqual(palette.amber, 0xa36802)
        XCTAssertEqual(palette.ok, 0x176839)
        XCTAssertEqual(palette.consoleError, 0xda4453)
        XCTAssertEqual(palette.repoColors, [0xbe5a00, 0x0b8a0f, 0x2980b9, 0x9b59b6])
    }

    /// 2610.0007 S10 — G4: ANSI 7 and ANSI 15 are dark greys.
    func testS10TheLightTerminalIsBreezeLight() {
        let terminal = ThemeCatalog.standard(for: .light).palette.terminal

        XCTAssertEqual(terminal.foreground, 0x232629)
        XCTAssertEqual(terminal.background, 0xfcfcfc)
        XCTAssertEqual(terminal.cursor, 0x232629)
        XCTAssertEqual(terminal.selection, 0x12846e)
        XCTAssertEqual(terminal.selectionAlpha, 0.3)
        XCTAssertEqual(terminal.ansi, [
            0x232627, 0xed1515, 0x0b8a0f, 0xbe5a00, 0x2980b9, 0x9b59b6, 0x12846e, 0x63686d,
            0x7f8c8d, 0xc0392b, 0x11865e, 0xa36802, 0x147db3, 0x8e44ad, 0x16a085, 0x232629,
        ])
    }

    /// S10 — the thumb is the same thumb in every theme, and the selection
    /// is the theme's own accent.
    func testS10TheScrollThumbAndTheSelectionFollowOneRuleInEveryTheme() {
        for entry in ThemeCatalog.all {
            XCTAssertEqual(entry.palette.scrollThumb, 0x181b1d, entry.id)
            XCTAssertEqual(entry.palette.scrollThumbLine, 0x696b6c, entry.id)
            XCTAssertEqual(entry.palette.terminal.selection, entry.palette.agent, entry.id)
            XCTAssertEqual(entry.palette.terminal.selectionAlpha, 0.3, entry.id)
        }
    }

    /// S11 — the rule of `TerminalTheme.isDark`: luminance, and a tie is light.
    func testS11APaletteIsDarkWhenItsTerminalBackgroundHasLessLuminanceThanItsForeground() {
        let base = ThemeCatalog.theme("breeze-light").palette

        XCTAssertEqual(base.changed(terminalForeground: 0x232629, terminalBackground: 0xfcfcfc).variant, .light)
        XCTAssertEqual(base.changed(terminalForeground: 0xfcfcfc, terminalBackground: 0x232629).variant, .dark)
        XCTAssertEqual(base.changed(terminalForeground: 0x808080, terminalBackground: 0x808080).variant, .light)
        XCTAssertEqual(base.changed(terminalForeground: 0x00a000, terminalBackground: 0x0000ff).variant, .dark)
    }

    /// S11
    func testS11EveryThemeHasTheVariantOfTheCatalogueTable() {
        XCTAssertEqual(
            ThemeCatalog.all.map(\.variant), [.light, .dark, .light, .dark, .light, .dark, .light, .dark]
        )
    }

    /// S9
    func testS9CatppuccinLatteHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("catppuccin-latte").palette

        XCTAssertEqual(palette.bg0, 0xdce0e8)
        XCTAssertEqual(palette.bg1, 0xe6e9ef)
        XCTAssertEqual(palette.bg2, 0xccd0da)
        XCTAssertEqual(palette.bg3, 0xbcc0cc)
        XCTAssertEqual(palette.primeHeaderBg, 0xc4c8d3)
        XCTAssertEqual(palette.line, 0xacb0be)
        XCTAssertEqual(palette.lineSoft, 0xbcc0cc)
        XCTAssertEqual(palette.liftBorder, 0x8c8fa1)
        XCTAssertEqual(palette.text, 0x4c4f69)
        XCTAssertEqual(palette.muted, 0x55586e)
        XCTAssertEqual(palette.faint, 0x7c7f93)
        XCTAssertEqual(palette.prose, 0x4c4f69)
        XCTAssertEqual(palette.agent, 0x148187)
        XCTAssertEqual(palette.amber, 0xa26715)
        XCTAssertEqual(palette.ok, 0x358423)
        XCTAssertEqual(palette.consoleError, 0xd20f39)
        XCTAssertEqual(palette.repoColors, [0xc84a01, 0x358423, 0x1e66f5, 0x8839ef])
        XCTAssertEqual(palette.terminal.foreground, 0x4c4f69)
        XCTAssertEqual(palette.terminal.background, 0xeff1f5)
        XCTAssertEqual(palette.terminal.cursor, 0xdc8a78)
        XCTAssertEqual(palette.terminal.ansi, [
            0xbcc0cc, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0x5c5f77,
            0xacb0be, 0xe7103f, 0x46b02f, 0xe49931, 0x3878f6, 0xef95d7, 0x19a1a8, 0x6c6f85,
        ])
    }

    /// S9
    func testS9CatppuccinMochaHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("catppuccin-mocha").palette

        XCTAssertEqual(palette.bg0, 0x11111b)
        XCTAssertEqual(palette.bg1, 0x181825)
        XCTAssertEqual(palette.bg2, 0x313244)
        XCTAssertEqual(palette.bg3, 0x45475a)
        XCTAssertEqual(palette.primeHeaderBg, 0x3b3c4f)
        XCTAssertEqual(palette.line, 0x585b70)
        XCTAssertEqual(palette.lineSoft, 0x45475a)
        XCTAssertEqual(palette.liftBorder, 0x6c7086)
        XCTAssertEqual(palette.text, 0xcdd6f4)
        XCTAssertEqual(palette.muted, 0xa6adc8)
        XCTAssertEqual(palette.faint, 0x7f849c)
        XCTAssertEqual(palette.prose, 0xbac2de)
        XCTAssertEqual(palette.agent, 0x94e2d5)
        XCTAssertEqual(palette.amber, 0xf9e2af)
        XCTAssertEqual(palette.ok, 0xa6e3a1)
        XCTAssertEqual(palette.consoleError, 0xf38ba8)
        XCTAssertEqual(palette.repoColors, [0xfab387, 0xa6e3a1, 0x89b4fa, 0xcba6f7])
        XCTAssertEqual(palette.terminal.foreground, 0xcdd6f4)
        XCTAssertEqual(palette.terminal.background, 0x1e1e2e)
        XCTAssertEqual(palette.terminal.cursor, 0xf5e0dc)
        XCTAssertEqual(palette.terminal.ansi, [
            0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
            0x585b70, 0xf7aec2, 0xc2ecbf, 0xfcd682, 0xaeccfc, 0xf398da, 0xb1eae1, 0xa6adc8,
        ])
    }

    /// S9
    func testS9GithubLightHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("github-light").palette

        XCTAssertEqual(palette.bg0, 0xeaeef2)
        XCTAssertEqual(palette.bg1, 0xf6f8fa)
        XCTAssertEqual(palette.bg2, 0xe1e6eb)
        XCTAssertEqual(palette.bg3, 0xd0d7de)
        XCTAssertEqual(palette.primeHeaderBg, 0xd8dee4)
        XCTAssertEqual(palette.line, 0xafb8c1)
        XCTAssertEqual(palette.lineSoft, 0xd0d7de)
        XCTAssertEqual(palette.liftBorder, 0x8c959f)
        XCTAssertEqual(palette.text, 0x1f2328)
        XCTAssertEqual(palette.muted, 0x5f676f)
        XCTAssertEqual(palette.faint, 0x6e7781)
        XCTAssertEqual(palette.prose, 0x24292f)
        XCTAssertEqual(palette.agent, 0x1b7c83)
        XCTAssertEqual(palette.amber, 0x9a6700)
        XCTAssertEqual(palette.ok, 0x1a7f37)
        XCTAssertEqual(palette.consoleError, 0xd1242f)
        XCTAssertEqual(palette.repoColors, [0xbc4c00, 0x1a7f37, 0x0969da, 0x8250df])
        XCTAssertEqual(palette.terminal.foreground, 0x1f2328)
        XCTAssertEqual(palette.terminal.background, 0xffffff)
        XCTAssertEqual(palette.terminal.cursor, 0x0969da)
        XCTAssertEqual(palette.terminal.ansi, [
            0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
            0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f,
        ])
    }

    /// S9
    func testS9GithubDarkHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("github-dark").palette

        XCTAssertEqual(palette.bg0, 0x010409)
        XCTAssertEqual(palette.bg1, 0x070a10)
        XCTAssertEqual(palette.bg2, 0x161b22)
        XCTAssertEqual(palette.bg3, 0x21262d)
        XCTAssertEqual(palette.primeHeaderBg, 0x1c2028)
        XCTAssertEqual(palette.line, 0x30363d)
        XCTAssertEqual(palette.lineSoft, 0x21262d)
        XCTAssertEqual(palette.liftBorder, 0x484f58)
        XCTAssertEqual(palette.text, 0xe6edf3)
        XCTAssertEqual(palette.muted, 0x848d97)
        XCTAssertEqual(palette.faint, 0x6e7681)
        XCTAssertEqual(palette.prose, 0xc9d1d9)
        XCTAssertEqual(palette.agent, 0x39c5cf)
        XCTAssertEqual(palette.amber, 0xd29922)
        XCTAssertEqual(palette.ok, 0x3fb950)
        XCTAssertEqual(palette.consoleError, 0xf85149)
        XCTAssertEqual(palette.repoColors, [0xdb6d28, 0x3fb950, 0x2f81f7, 0xa371f7])
        XCTAssertEqual(palette.terminal.foreground, 0xe6edf3)
        XCTAssertEqual(palette.terminal.background, 0x0d1117)
        XCTAssertEqual(palette.terminal.cursor, 0x2f81f7)
        XCTAssertEqual(palette.terminal.ansi, [
            0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
            0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xffffff,
        ])
    }

    /// S9
    func testS9SolarizedLightHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("solarized-light").palette

        XCTAssertEqual(palette.bg0, 0xeee8d5)
        XCTAssertEqual(palette.bg1, 0xf6efdc)
        XCTAssertEqual(palette.bg2, 0xe5e1cf)
        XCTAssertEqual(palette.bg3, 0xd9d7c8)
        XCTAssertEqual(palette.primeHeaderBg, 0xdedbca)
        XCTAssertEqual(palette.line, 0xc1c3b8)
        XCTAssertEqual(palette.lineSoft, 0xd4d3c5)
        XCTAssertEqual(palette.liftBorder, 0x93a1a1)
        XCTAssertEqual(palette.text, 0x073642)
        XCTAssertEqual(palette.muted, 0x53676e)
        XCTAssertEqual(palette.faint, 0x839496)
        XCTAssertEqual(palette.prose, 0x586e75)
        XCTAssertEqual(palette.agent, 0x258d85)
        XCTAssertEqual(palette.amber, 0xa17a00)
        XCTAssertEqual(palette.ok, 0x758700)
        XCTAssertEqual(palette.consoleError, 0xdc322f)
        XCTAssertEqual(palette.repoColors, [0xcb4b16, 0x758700, 0x2485c9, 0x6c71c4])
        XCTAssertEqual(palette.terminal.foreground, 0x657b83)
        XCTAssertEqual(palette.terminal.background, 0xfdf6e3)
        XCTAssertEqual(palette.terminal.cursor, 0x657b83)
        XCTAssertEqual(palette.terminal.ansi, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xbbb5a2,
            0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ])
    }

    /// S9
    func testS9SolarizedDarkHasTheValuesOfItsTable() {
        let palette = ThemeCatalog.theme("solarized-dark").palette

        XCTAssertEqual(palette.bg0, 0x001e26)
        XCTAssertEqual(palette.bg1, 0x00252e)
        XCTAssertEqual(palette.bg2, 0x073642)
        XCTAssertEqual(palette.bg3, 0x16404b)
        XCTAssertEqual(palette.primeHeaderBg, 0x0f3c47)
        XCTAssertEqual(palette.line, 0x264b55)
        XCTAssertEqual(palette.lineSoft, 0x16404b)
        XCTAssertEqual(palette.liftBorder, 0x586e75)
        XCTAssertEqual(palette.text, 0xeee8d5)
        XCTAssertEqual(palette.muted, 0x93a1a1)
        XCTAssertEqual(palette.faint, 0x586e75)
        XCTAssertEqual(palette.prose, 0x839496)
        XCTAssertEqual(palette.agent, 0x2aa198)
        XCTAssertEqual(palette.amber, 0xb58900)
        XCTAssertEqual(palette.ok, 0x859900)
        XCTAssertEqual(palette.consoleError, 0xde3f3c)
        XCTAssertEqual(palette.repoColors, [0xd44e17, 0x859900, 0x268bd2, 0x6e73c5])
        XCTAssertEqual(palette.terminal.foreground, 0x839496)
        XCTAssertEqual(palette.terminal.background, 0x002b36)
        XCTAssertEqual(palette.terminal.cursor, 0x839496)
        XCTAssertEqual(palette.terminal.ansi, [
            0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
            0x335e69, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3,
        ])
    }

    /// The lighter of two colours has the lower contrast against white.
    private func isLighter(_ a: UInt32, than b: UInt32) -> Bool {
        Contrast.ratio(a, 0xffffff) < Contrast.ratio(b, 0xffffff)
    }

    /// 2610.0007 S14
    func testS14TheLightPaletteIsLightAndTheDarkOneDark() {
        let light = ThemeCatalog.standard(for: .light).palette, dark = ThemeCatalog.standard(for: .dark).palette

        XCTAssertTrue(isLighter(light.terminal.background, than: light.terminal.foreground))
        XCTAssertTrue(isLighter(light.bg0, than: light.text))
        XCTAssertTrue(isLighter(dark.terminal.foreground, than: dark.terminal.background))
        XCTAssertTrue(isLighter(dark.text, than: dark.bg0))
    }
}
