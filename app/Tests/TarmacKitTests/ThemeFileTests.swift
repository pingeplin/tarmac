import XCTest

@testable import TarmacKit

/// Spec 2610.0009: what the text of a theme file gives, why a file is
/// refused, and every colour the file does not give.
final class ThemeFileTests: XCTestCase {
    private func parsed(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ThemeFile.Colours? {
        switch ThemeFile.parse(text) {
        case .success(let colours): return colours
        case .failure(let refusal):
            XCTFail("refused: \(refusal)", file: file, line: line)
            return nil
        }
    }

    private func refusal(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> ThemeFile.Refusal? {
        switch ThemeFile.parse(text) {
        case .success(let colours):
            XCTFail("read: \(colours)", file: file, line: line)
            return nil
        case .failure(let refusal): return refusal
        }
    }

    // MARK: - The grammar

    /// "Dracula text parses to its colours"
    func testTheDraculaTextGivesItsTerminalColours() {
        XCTAssertEqual(parsed(ThemeFixture.dracula), ThemeFixture.draculaColours)
    }

    /// "Every line form parses the same"
    func testEveryFormOfALineIsRead() {
        let text = [
            "# a comment", "", "\tbackground\t=\t\"#FFF\"", "foreground=000000", "  palette = 3 = #AbC",
            "palette=15=1a2B3c", "cursor-color = \" #123 \"",
        ].joined(separator: "\r\n")

        XCTAssertEqual(
            parsed(text),
            ThemeFile.Colours(
                background: 0xffffff, foreground: 0x000000, cursor: 0x112233,
                ansi: [3: 0xaabbcc, 15: 0x1a2b3c], chrome: [:], repo: [:]
            )
        )
    }

    /// "Every line form parses the same" — the quotes are those of the line's value.
    func testAQuotedPaletteValueIsRead() {
        XCTAssertEqual(parsed(ThemeFixture.text("palette = \"7 = #010203\""))?.ansi, [7: 0x010203])
    }

    /// "Unused lines change nothing"
    func testALineThatIsNotAUsedKeyChangesNothing() {
        let others = [
            "selection-background = not a colour", "cursor-text = x", "font-family = Menlo", "theme = other", "hello",
            "Background = red", "tarmac-scroll-thumb = #fff", "palette-generate = true",
        ].joined(separator: "\n")

        XCTAssertEqual(parsed(others + "\n" + ThemeFixture.dracula), ThemeFixture.draculaColours)
    }

    /// "Last line wins and empty value removes"
    func testTheLastLineWins() {
        XCTAssertEqual(parsed("background = #111111\nforeground = #fff\nbackground = #222222")?.background, 0x222222)
        XCTAssertEqual(parsed(ThemeFixture.text("palette = 1=#111111", "palette = 1=#222222"))?.ansi, [1: 0x222222])
    }

    /// "Last line wins and empty value removes"
    func testAnEmptyValueTakesAway() {
        for second in [
            "cursor-color =", "cursor-color = \"\"", "cursor-color = cell-foreground", "cursor-color = cell-background",
        ] {
            let colours = parsed(ThemeFixture.text("cursor-color = #ff0000", second))
            XCTAssertNotNil(colours, second)
            XCTAssertNil(colours?.cursor, second)
        }
        XCTAssertEqual(
            parsed(ThemeFixture.text("palette = 1=#111111", "palette = 2=#222222", "palette =", "palette = 3=#333333"))?
                .ansi,
            [3: 0x333333]
        )
        XCTAssertEqual(parsed(ThemeFixture.text("tarmac-repo = 0=#111111", "tarmac-repo ="))?.repo, [:])
        XCTAssertEqual(parsed(ThemeFixture.text("tarmac-bg0 = #111111", "tarmac-bg0 ="))?.chrome, [:])
    }

    /// "Palette index outside range is skipped"
    func testAPaletteEntryOver15IsReadAndNotUsed() {
        XCTAssertEqual(
            parsed(ThemeFixture.text("palette = 16=#111111", "palette = 255=#222222", "palette = 007=#333333"))?.ansi,
            [7: 0x333333]
        )
    }

    /// "Bad lines are refused with their line number"
    func testAUsedKeyWithAValueThatIsNotReadRefusesTheFile() {
        let bad: [(line: String, key: String)] = [
            ("background = red", "background"), ("background = #12345", "background"),
            ("background = #1234567", "background"), ("background = #fff # x", "background"),
            ("background = cell-background", "background"), ("foreground", "foreground"),
            ("cursor-color = cell-text", "cursor-color"), ("palette = 16", "palette"), ("palette = x=#fff", "palette"),
            ("palette = 256=#fff", "palette"), ("palette = 0x0f=#fff", "palette"), ("palette = -1=#fff", "palette"),
            ("palette = +1=#fff", "palette"), ("palette = 1=", "palette"), ("palette = 1=red", "palette"),
            ("tarmac-repo = 4=#fff", "tarmac-repo"), ("tarmac-bg0 = cell-foreground", "tarmac-bg0"),
            ("tarmac-console-error = #gggggg", "tarmac-console-error"),
            ("background = #fff\u{a0}", "background"), ("background = #\u{ff46}\u{ff46}\u{ff46}", "background"),
            ("palette = 200=red", "palette"), ("palette = =#fff", "palette"),
            ("palette = 99999999999999999999=#fff", "palette"), ("palette = 1=\"#fff\"", "palette"),
            ("background = \"", "background"), ("palette = \u{ff11}=#fff", "palette"),
        ]
        for (line, key) in bad {
            XCTAssertEqual(refusal(ThemeFixture.text(line)), .value(line: 3, key: key), line)
        }
    }

    /// "Bad lines are refused with their line number" — a line number counts every line, and the first bad line is told.
    func testTheFirstBadLineIsTold() {
        let text = [
            "# a comment", "", "background = #000", "foreground = #fff", "palette = x=#fff", "palette = 1=#111",
            "cursor-color = red",
        ].joined(separator: "\n")

        XCTAssertEqual(refusal(text), .value(line: 5, key: "palette"))
    }

    /// "Missing background or foreground is refused"
    func testAFileMustHaveABackgroundAndAForeground() {
        XCTAssertEqual(refusal("foreground = #fff"), .missing(key: "background"))
        XCTAssertEqual(refusal("palette = 1=#fff"), .missing(key: "background"))
        XCTAssertEqual(refusal("background = #000"), .missing(key: "foreground"))
        XCTAssertEqual(refusal("background = #000\nforeground = #fff\nbackground ="), .missing(key: "background"))
        XCTAssertEqual(refusal("foreground = #fff\npalette = x=#fff"), .value(line: 2, key: "palette"))
    }

    /// "Chrome and repo keys parse to entries"
    func testEachTarmacKeyGivesItsOwnEntry() {
        XCTAssertEqual(
            ThemeFile.ChromeKey.allCases.map(\.fileKey),
            [
                "tarmac-bg0", "tarmac-bg1", "tarmac-bg2", "tarmac-bg3", "tarmac-line", "tarmac-line-soft",
                "tarmac-lift-border", "tarmac-prime-header-bg", "tarmac-text", "tarmac-muted", "tarmac-faint",
                "tarmac-prose", "tarmac-agent", "tarmac-amber", "tarmac-ok", "tarmac-console-error",
            ]
        )
        for key in ThemeFile.ChromeKey.allCases {
            XCTAssertEqual(parsed(ThemeFixture.text("\(key.fileKey) = #123456"))?.chrome, [key: 0x123456], key.fileKey)
        }
        XCTAssertEqual(parsed(ThemeFixture.text("tarmac-repo = 2=#123456"))?.repo, [2: 0x123456])
        XCTAssertEqual(parsed(ThemeFixture.text("tarmac-repo = 3=#123456"))?.repo, [3: 0x123456])
    }

    /// "Bytes decode with or without a BOM" — `String(data:encoding:)` drops a mark by itself, so this is the
    /// check that holds the rule of `parse`.
    func testParseDropsAByteOrderMark() {
        XCTAssertEqual(parsed("\u{FEFF}" + ThemeFixture.dracula), ThemeFixture.draculaColours)
    }

    /// "Refusals have readable reason and detail"
    func testARefusalHasItsReasonInWords() {
        XCTAssertEqual(ThemeFile.Refusal.unreadable.reason, "cannot be read")
        XCTAssertEqual(ThemeFile.Refusal.tooLarge.reason, "is larger than 64 KiB")
        XCTAssertEqual(ThemeFile.Refusal.notText.reason, "is not UTF-8 text")
        XCTAssertEqual(
            ThemeFile.Refusal.value(line: 12, key: "palette").reason, "line 12: the value of palette cannot be read"
        )
        XCTAssertEqual(ThemeFile.Refusal.missing(key: "background").reason, "has no background")
        XCTAssertEqual(ThemeFile.Refusal.missing(key: "foreground").reason, "has no foreground")
    }

    // MARK: - The derived colours

    private static let breezeDarkANSI = ThemeCatalog.standard(for: .dark).palette.terminal.ansi
    private static let breezeLightANSI = ThemeCatalog.standard(for: .light).palette.terminal.ansi

    private static let dracula = Palette(
        bg0: 0x171a27, bg1: 0x20222e, bg2: 0x373843, bg3: 0x474952,
        line: 0x5a5b63, lineSoft: 0x474952, liftBorder: 0x7b7c81, primeHeaderBg: 0x3f414b,
        text: 0xf8f8f2, muted: 0xc4c5c3, faint: 0x9a9b9d, prose: 0xf8f8f2,
        agent: 0x8be9fd, amber: 0xf1fa8c, ok: 0x50fa7b, consoleError: 0xff5555,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xf1fa8c, 0x50fa7b, 0xbd93f9, 0xff79c6],
        terminal: Palette.Terminal(
            foreground: 0xf8f8f2, background: 0x282a36, cursor: 0xf8f8f2, selection: 0x8be9fd, selectionAlpha: 0.3,
            ansi: ThemeFixture.draculaANSI
        )
    )

    private static let latte = Palette(
        bg0: 0xdfe1e7, bg1: 0xe7e9ee, bg2: 0xd7d9e0, bg3: 0xcaccd5,
        line: 0xb4b7c3, lineSoft: 0xc6c9d2, liftBorder: 0x9598a8, primeHeaderBg: 0xced1d9,
        text: 0x4c4f69, muted: 0x585a69, faint: 0x9598a8, prose: 0x4c4f69,
        agent: 0x148086, amber: 0xa76b16, ok: 0x388c26, consoleError: 0xd20f39,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xa76b16, 0x388c26, 0x1e66f5, 0xb05998],
        terminal: Palette.Terminal(
            foreground: 0x4c4f69, background: 0xeff1f5, cursor: 0xdc8a78, selection: 0x148086, selectionAlpha: 0.3,
            ansi: (0..<16).map { ThemeFixture.latteColours.ansi[$0]! }
        )
    )

    private static let black = Palette(
        bg0: 0x000000, bg1: 0x000000, bg2: 0x121212, bg3: 0x262626,
        line: 0x3d3d3d, lineSoft: 0x262626, liftBorder: 0x666666, primeHeaderBg: 0x1c1c1c,
        text: 0xffffff, muted: 0xbfbfbf, faint: 0x8c8c8c, prose: 0xffffff,
        agent: 0x1abc9c, amber: 0xf67400, ok: 0x11d116, consoleError: 0xed1515,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xf67400, 0x11d116, 0x1d99f3, 0x9b59b6],
        terminal: Palette.Terminal(
            foreground: 0xffffff, background: 0x000000, cursor: 0xffffff, selection: 0x1abc9c, selectionAlpha: 0.3,
            ansi: breezeDarkANSI
        )
    )

    private static let white = Palette(
        bg0: 0xe6e6e6, bg1: 0xf2f2f2, bg2: 0xd9d9d9, bg3: 0xc4c4c4,
        line: 0xa3a3a3, lineSoft: 0xbfbfbf, liftBorder: 0x737373, primeHeaderBg: 0xcccccc,
        text: 0x000000, muted: 0x404040, faint: 0x737373, prose: 0x000000,
        agent: 0x12846e, amber: 0xbe5a00, ok: 0x0b8a0f, consoleError: 0xed1515,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0xbe5a00, 0x0b8a0f, 0x2980b9, 0x9b59b6],
        terminal: Palette.Terminal(
            foreground: 0x000000, background: 0xffffff, cursor: 0x000000, selection: 0x12846e, selectionAlpha: 0.3,
            ansi: breezeLightANSI
        )
    )

    /// The last column of the vector table: a given `bg2` moves every lift.
    private static let latteWithBg2 = Palette(
        bg0: 0xdfe1e7, bg1: 0xe7e9ee, bg2: 0x9ca0b0, bg3: 0xcaccd5,
        line: 0xb4b7c3, lineSoft: 0xc6c9d2, liftBorder: 0x9598a8, primeHeaderBg: 0xced1d9,
        text: 0x343648, muted: 0x33353d, faint: 0x9598a8, prose: 0x4c4f69,
        agent: 0x0e5b60, amber: 0x70470f, ok: 0x245a18, consoleError: 0x9e0b2b,
        scrollThumb: 0x181b1d, scrollThumbLine: 0x696b6c,
        repoColors: [0x70470f, 0x245a18, 0x1546a8, 0x753b66],
        terminal: Palette.Terminal(
            foreground: 0x4c4f69, background: 0xeff1f5, cursor: 0xdc8a78, selection: 0x0e5b60, selectionAlpha: 0.3,
            ansi: (0..<16).map { ThemeFixture.latteColours.ansi[$0]! }
        )
    )

    private func token(_ key: ThemeFile.ChromeKey, of palette: Palette) -> UInt32 {
        switch key {
        case .bg0: palette.bg0
        case .bg1: palette.bg1
        case .bg2: palette.bg2
        case .bg3: palette.bg3
        case .line: palette.line
        case .lineSoft: palette.lineSoft
        case .liftBorder: palette.liftBorder
        case .primeHeaderBg: palette.primeHeaderBg
        case .text: palette.text
        case .muted: palette.muted
        case .faint: palette.faint
        case .prose: palette.prose
        case .agent: palette.agent
        case .amber: palette.amber
        case .ok: palette.ok
        case .consoleError: palette.consoleError
        }
    }

    private func subjects(_ findings: [PaletteCheck.Finding], _ part: PaletteCheck.Finding.Part) -> [String] {
        findings.filter { $0.part == part }.map { "\($0.subject) on \($0.ground)" }
    }

    /// "Bytes decode with or without a BOM"
    func testBytesThatAreNotUTF8AreNotText() {
        XCTAssertEqual(ThemeFile.palette(of: Data([0xff, 0xfe, 0x00])), .failure(.notText))
    }

    /// "Bytes decode with or without a BOM"
    func testTheBytesOfAFileGiveItsPalette() {
        let text = Data(ThemeFixture.dracula.utf8)

        XCTAssertEqual(ThemeFile.palette(of: text), .success(Self.dracula))
        XCTAssertEqual(ThemeFile.palette(of: Data([0xef, 0xbb, 0xbf]) + text), .success(Self.dracula))
    }

    /// "Dracula colours give the vector palette"
    func testDraculaHasTheValuesOfItsColumn() {
        XCTAssertEqual(ThemeFile.palette(from: ThemeFixture.draculaColours), Self.dracula)
    }

    /// "Latte colours give the lifted palette" — with no lift `agent` is ANSI 6, `179299`.
    func testLatteHasTheValuesOfItsColumn() {
        XCTAssertEqual(ThemeFile.palette(from: ThemeFixture.latteColours), Self.latte)
    }

    /// "Black and White themes derive full palettes" — a mix that goes under 0 is held at 0.
    func testAFileWithTwoColoursIsAWholeTheme() {
        XCTAssertEqual(ThemeFile.palette(from: ThemeFixture.black), Self.black)
        XCTAssertEqual(ThemeFile.palette(from: ThemeFixture.white), Self.white)
    }

    /// "Black and White themes derive full palettes" — and a mix that goes over 255 is held at 255: the blue of the
    /// background is the far side of the foreground's.
    func testAMixIsHeldAt255() {
        let palette = ThemeFile.palette(from: ThemeFixture.colours(background: 0x0000ff, foreground: 0xffff00))

        XCTAssertEqual(palette.variant, .dark)
        XCTAssertEqual(palette.bg0, 0x0000ff)
    }

    /// "Black and White themes derive full palettes"
    func testAMissingANSIColourIsTheStandardThemes() {
        var colours = ThemeFixture.black
        colours.ansi = [6: 0xff00ff]

        let palette = ThemeFile.palette(from: colours)

        XCTAssertEqual(
            palette.terminal.ansi, Self.breezeDarkANSI.enumerated().map { $0.offset == 6 ? 0xff00ff : $0.element })
        XCTAssertEqual(palette.agent, 0xff00ff)
    }

    /// "Three given keys leave exact findings" — a given colour is not lifted, also under its floor.
    func testAGivenColourIsNotChanged() {
        var colours = ThemeFixture.draculaColours
        colours.chrome = [.bg0: 0x101010, .agent: 0xff00ff, .muted: 0x6272a4]

        let palette = ThemeFile.palette(from: colours)

        XCTAssertEqual(
            palette,
            Self.dracula.changed(bg0: 0x101010, muted: 0x6272a4, agent: 0xff00ff, terminalSelection: 0xff00ff)
        )
        let findings = PaletteCheck.findings(palette)
        XCTAssertEqual(subjects(findings, .chrome), ["muted on bg0", "muted on bg1", "muted on bg2"])
        XCTAssertEqual(subjects(findings, .terminal), ["ansi 0 on background"])
    }

    /// "Three given keys leave exact findings" — the lift measures against the fills of the result.
    func testAGivenFillMovesEveryLift() {
        XCTAssertEqual(ThemeFile.palette(from: ThemeFixture.latteWithBg2Colours), Self.latteWithBg2)
    }

    /// "Three given keys leave exact findings"
    func testEachChromeKeyReachesItsOwnToken() {
        for key in ThemeFile.ChromeKey.allCases {
            var colours = ThemeFixture.black
            colours.chrome = [key: 0x123456]

            XCTAssertEqual(token(key, of: ThemeFile.palette(from: colours)), 0x123456, key.fileKey)
        }
    }

    /// "Three given keys leave exact findings"
    func testAGivenRepoColourIsNotLiftedAndTheOthersAreDerived() {
        var colours = ThemeFixture.draculaColours
        colours.repo = [2: 0x123456]

        XCTAssertEqual(ThemeFile.palette(from: colours).repoColors, [0xf1fa8c, 0x50fa7b, 0x123456, 0xff79c6])
    }

    /// "Derived palettes share fixed tokens and variant"
    func testTheFixedPartsFollowOneRuleInEveryDerivedTheme() {
        let columns: [(ThemeFile.Colours, ThemeVariant)] = [
            (ThemeFixture.draculaColours, .dark), (ThemeFixture.latteColours, .light), (ThemeFixture.black, .dark),
            (ThemeFixture.white, .light), (ThemeFixture.latteWithBg2Colours, .light),
        ]
        for (colours, variant) in columns {
            let palette = ThemeFile.palette(from: colours)

            XCTAssertEqual(palette.scrollThumb, 0x181b1d)
            XCTAssertEqual(palette.scrollThumbLine, 0x696b6c)
            XCTAssertEqual(palette.terminal.selectionAlpha, 0.3)
            XCTAssertEqual(palette.terminal.selection, palette.agent)
            XCTAssertEqual(palette.repoColors.count, 4)
            XCTAssertEqual(palette.terminal.ansi.count, 16)
            XCTAssertEqual(palette.variant, variant)
        }
    }

    /// "Derived palettes share fixed tokens and variant" — equal luminance is light, so the pole is black.
    func testAFileOfOneGreyIsLight() {
        let palette = ThemeFile.palette(from: ThemeFixture.colours(background: 0x808080, foreground: 0x808080))

        XCTAssertEqual(palette.variant, .light)
        XCTAssertEqual(palette.text, 0x101010)
    }

    /// "Hot Dog Stand gives its contract values" — the detector warns, and nothing refuses.
    func testAThemeThatNoLiftCanMendIsStillATheme() {
        let palette = ThemeFile.palette(from: ThemeFixture.hotDogStandColours)

        XCTAssertEqual(palette.text, 0xffffff)
        XCTAssertEqual(palette.muted, 0xffffff)
        XCTAssertEqual([palette.bg0, palette.bg1, palette.bg2], [0xe82311, 0xe92b1a, 0xeb4132])
        XCTAssertEqual(palette.repoColors, [0xffff54, 0xffff54, 0x000000, 0xffff54])
        let findings = PaletteCheck.findings(palette)
        XCTAssertEqual(
            subjects(findings, .chrome),
            ["text on bg0", "muted on bg0", "text on bg1", "muted on bg1", "text on bg2", "muted on bg2"]
        )
        XCTAssertEqual(
            subjects(findings, .terminal),
            ["ansi 7 on background", "ansi 15 on background", "foreground on background"]
        )
    }
}
