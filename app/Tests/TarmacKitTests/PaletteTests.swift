import XCTest
@testable import TarmacKit

/// 2610.0007: the colours of Breeze Dark and Breeze Light. The expected values
/// are the tables of the spec, which is the contract for them.
final class PaletteTests: XCTestCase {
    private let variants = [ThemeVariant.dark, .light]

    /// S8
    func testS8APaletteHasFourRepoColoursAndSixteenANSIColours() {
        for variant in variants {
            XCTAssertEqual(Palette.of(variant).repoColors.count, 4, "\(variant)")
            XCTAssertEqual(Palette.of(variant).terminal.ansi.count, 16, "\(variant)")
        }
    }

    /// S9 — the look of `289d208`, with no change.
    func testS9TheDarkPaletteIsTheLookOfToday() {
        let palette = Palette.of(.dark)

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

    /// S9
    func testS9TheDarkTerminalIsBreeze() {
        let terminal = Palette.of(.dark).terminal

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

    /// S10
    func testS10TheLightPaletteIsBreezeLight() {
        let palette = Palette.of(.light)

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

    /// S10 — G5: the scroll thumb is the same thumb in the two themes.
    func testS10TheLightScrollThumbIsTheDarkOne() {
        let palette = Palette.of(.light)

        XCTAssertEqual(palette.scrollThumb, 0x181b1d)
        XCTAssertEqual(palette.scrollThumbLine, 0x696b6c)
    }

    /// S10 — G4: ANSI 7 and ANSI 15 are dark greys.
    func testS10TheLightTerminalIsBreezeLight() {
        let terminal = Palette.of(.light).terminal

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

    /// S12 — a colour a program prints can be read on the light body.
    func testS12EveryLightANSIColourCanBeReadOnTheLightBackground() {
        let terminal = Palette.of(.light).terminal

        for (index, colour) in terminal.ansi.enumerated() {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(colour, terminal.background), 3, "ANSI \(index)")
        }
        XCTAssertGreaterThanOrEqual(Contrast.ratio(terminal.foreground, terminal.background), 7)
    }

    /// S13
    func testS13TextAndMarksCanBeReadOnEveryChromeFill() {
        for variant in variants {
            let palette = Palette.of(variant)
            let fills = [("bg0", palette.bg0), ("bg1", palette.bg1), ("bg2", palette.bg2)]
            let text = [("text", palette.text), ("muted", palette.muted)]
            let marks = [
                ("agent", palette.agent), ("amber", palette.amber), ("ok", palette.ok),
                ("consoleError", palette.consoleError),
            ]

            for (fillName, fill) in fills {
                for (name, colour) in text {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(colour, fill), 4.5, "\(variant) \(name) on \(fillName)")
                }
                for (name, colour) in marks {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(colour, fill), 3, "\(variant) \(name) on \(fillName)")
                }
            }
        }
    }

    /// The lighter of two colours has the lower contrast against white.
    private func isLighter(_ a: UInt32, than b: UInt32) -> Bool {
        Contrast.ratio(a, 0xffffff) < Contrast.ratio(b, 0xffffff)
    }

    /// S14
    func testS14TheLightPaletteIsLightAndTheDarkOneDark() {
        let light = Palette.of(.light), dark = Palette.of(.dark)

        XCTAssertTrue(isLighter(light.terminal.background, than: light.terminal.foreground))
        XCTAssertTrue(isLighter(light.bg0, than: light.text))
        XCTAssertTrue(isLighter(dark.terminal.foreground, than: dark.terminal.background))
        XCTAssertTrue(isLighter(dark.text, than: dark.bg0))
    }
}
