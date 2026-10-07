import XCTest
@testable import TarmacKit

/// 2610.0008: the rules of the Theme pane's list and showcase.
final class ThemeBrowserTests: XCTestCase {
    private func box(_ shown: String, chosen: String, for variant: ThemeVariant) -> ThemeBrowser.Box {
        ThemeBrowser.box(shown: ThemeCatalog.theme(shown), chosen: ThemeCatalog.theme(chosen), for: variant)
    }

    /// S58
    func testS58ABoxIsOnForTheChosenThemeWhateverItsVariant() {
        XCTAssertEqual(
            box("catppuccin-mocha", chosen: "catppuccin-mocha", for: .dark),
            ThemeBrowser.Box(isOn: true, isEnabled: true)
        )
        XCTAssertEqual(
            box("catppuccin-mocha", chosen: "breeze-dark", for: .dark),
            ThemeBrowser.Box(isOn: false, isEnabled: true)
        )
    }

    /// S58 — there is no theme to go back to.
    func testS58TheBoxOfAStandardThemeThatIsChosenCannotBeCleared() {
        XCTAssertEqual(
            box("breeze-dark", chosen: "breeze-dark", for: .dark), ThemeBrowser.Box(isOn: true, isEnabled: false)
        )
        XCTAssertEqual(
            box("breeze-light", chosen: "breeze-light", for: .light), ThemeBrowser.Box(isOn: true, isEnabled: false)
        )
    }

    /// S58
    func testS58TheBoxOfAStandardThemeThatIsNotChosenCanBeSet() {
        XCTAssertEqual(
            box("breeze-dark", chosen: "catppuccin-mocha", for: .dark), ThemeBrowser.Box(isOn: false, isEnabled: true)
        )
    }

    /// S58 — a Breeze theme is locked only for the appearance it is the
    /// standard theme of.
    func testS58ABreezeThemeChosenForTheOtherAppearanceCanBeCleared() {
        XCTAssertEqual(
            box("breeze-dark", chosen: "breeze-dark", for: .light), ThemeBrowser.Box(isOn: true, isEnabled: true)
        )
        XCTAssertEqual(
            box("breeze-light", chosen: "breeze-light", for: .dark), ThemeBrowser.Box(isOn: true, isEnabled: true)
        )
    }

    private func toggled(_ shown: String, on: Bool, for variant: ThemeVariant) -> String {
        ThemeBrowser.toggled(shown: ThemeCatalog.theme(shown), on: on, for: variant).id
    }

    /// S59
    func testS59ASetBoxGivesTheShownThemeWhateverItsVariant() {
        XCTAssertEqual(toggled("catppuccin-mocha", on: true, for: .light), "catppuccin-mocha")
        XCTAssertEqual(toggled("github-light", on: true, for: .dark), "github-light")
    }

    /// S59 — of the box's appearance, not of the shown theme's variant.
    func testS59AClearedBoxGivesTheStandardThemeOfItsAppearance() {
        XCTAssertEqual(toggled("catppuccin-mocha", on: false, for: .light), "breeze-light")
        XCTAssertEqual(toggled("catppuccin-mocha", on: false, for: .dark), "breeze-dark")
        XCTAssertEqual(toggled("github-light", on: false, for: .dark), "breeze-dark")
    }

    /// S59
    func testS59ABoxThatWasSetIsOn() {
        var pairs = 0
        for shown in ThemeCatalog.all {
            for variant in ThemeVariant.allCases {
                let chosen = ThemeBrowser.toggled(shown: shown, on: true, for: variant)
                XCTAssertTrue(
                    ThemeBrowser.box(shown: shown, chosen: chosen, for: variant).isOn,
                    "\(shown.id) \(variant.rawValue)"
                )
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 16)
    }

    private let withDracula = ThemeLibrary(files: [ThemeFixture.file("Dracula")])

    private var dracula: ThemeCatalog.Entry { withDracula.entry("file:Dracula", for: .dark) }

    /// The marks of every theme of `library`, by id, with `themes` saved.
    private func marks(
        _ themes: [ThemeVariant: String], in library: ThemeLibrary = .shipped
    ) -> [String: [ThemeVariant]] {
        Dictionary(uniqueKeysWithValues: library.all.map { entry in
            (entry.id, ThemeBrowser.marks(of: entry) { library.entry(themes[$0], for: $0) })
        })
    }

    private func assertEachAppearanceMarksOneTheme(
        _ marks: [String: [ThemeVariant]], file: StaticString = #filePath, line: UInt = #line
    ) {
        for variant in ThemeVariant.allCases {
            XCTAssertEqual(
                marks.values.filter { $0.contains(variant) }.count, 1, variant.rawValue, file: file, line: line
            )
        }
    }

    /// S60 — a rule that compares the saved id with the entry's fails here:
    /// nothing is saved for a standard theme.
    func testS60WithNothingChosenTheMarksAreOnTheStandardThemes() {
        let marks = marks([:])

        XCTAssertEqual(marks["breeze-light"], [.light])
        XCTAssertEqual(marks["breeze-dark"], [.dark])
        XCTAssertEqual(marks.values.filter(\.isEmpty).count, 6)
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S60
    func testS60OneThemeHasBothMarksLightFirst() {
        let marks = marks([.light: "catppuccin-mocha", .dark: "catppuccin-mocha"])

        XCTAssertEqual(marks["catppuccin-mocha"], [.light, .dark])
        XCTAssertEqual(marks.values.filter(\.isEmpty).count, 7)
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S60 — a rule that gives an entry its own variant fails here.
    func testS60AMarkIsTheAppearanceTheThemeIsChosenForNotItsVariant() {
        let marks = marks([.dark: "solarized-light"])

        XCTAssertEqual(marks["solarized-light"], [.dark])
        XCTAssertEqual(marks["breeze-light"], [.light])
        XCTAssertEqual(marks["breeze-dark"], [])
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S60
    func testS60AnIdNoThemeHasLeavesTheMarkOnTheStandardTheme() {
        let marks = marks([.dark: "sepia"])

        XCTAssertEqual(marks["breeze-dark"], [.dark])
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S61 — the three forms. Solarized Light's eight are its seven ANSI
    /// findings and its foreground.
    func testS61TheNoteCountsTheTerminalColoursWithLowContrast() {
        XCTAssertEqual(
            ThemeBrowser.contrastNote(ThemeCatalog.theme("github-light").palette),
            "Every terminal colour passes the contrast floors."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(ThemeCatalog.theme("github-dark").palette),
            "1 terminal colour has low contrast on the background."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(ThemeCatalog.theme("catppuccin-latte").palette),
            "9 terminal colours have low contrast on the background."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(ThemeCatalog.theme("solarized-light").palette),
            "8 terminal colours have low contrast on the background."
        )
    }

    /// S61 — the numbers of the spec's table.
    func testS61EveryThemeHasTheNoteOfItsNumber() {
        let numbers = [
            "breeze-light": 0, "breeze-dark": 5, "catppuccin-latte": 9, "catppuccin-mocha": 2, "github-light": 0,
            "github-dark": 1, "solarized-light": 8, "solarized-dark": 4,
        ]
        XCTAssertEqual(Set(numbers.keys), Set(ThemeCatalog.all.map(\.id)))

        for entry in ThemeCatalog.all {
            let note = ThemeBrowser.contrastNote(entry.palette)
            if numbers[entry.id] == 0 {
                XCTAssertEqual(note, "Every terminal colour passes the contrast floors.", entry.id)
            } else {
                XCTAssertEqual(note.split(separator: " ").first.flatMap { Int($0) }, numbers[entry.id], entry.id)
            }
        }
    }

    /// 2610.0009 S36 — a note that counts findings and not colours says 3.
    func testS36AChromeColourWithLowContrastIsCountedOnce() {
        let breeze = ThemeCatalog.theme("breeze-light").palette
        let palette = breeze.changed(agent: breeze.bg0)
        let findings = PaletteCheck.findings(palette)
        XCTAssertEqual(findings.map(\.part), [.chrome, .chrome, .chrome])
        XCTAssertEqual(findings.map(\.subject), ["agent", "agent", "agent"])
        XCTAssertEqual(findings.map(\.ground), ["bg0", "bg1", "bg2"])

        XCTAssertEqual(
            ThemeBrowser.contrastNote(palette),
            "Every terminal colour passes the contrast floors. 1 chrome colour has low contrast."
        )
    }

    /// 2610.0009 S36 — six chrome findings of two colours.
    func testS36TheNoteCountsTheTerminalAndTheChromeColours() {
        XCTAssertEqual(
            ThemeBrowser.contrastNote(ThemeFile.palette(from: ThemeFixture.hotDogStandColours)),
            "3 terminal colours have low contrast on the background. 2 chrome colours have low contrast."
        )
    }

    /// 2610.0009 S37
    func testS37TheDetailHasOneLineForEachFinding() {
        XCTAssertEqual(
            ThemeBrowser.contrastDetail(ThemeCatalog.theme("github-dark").palette),
            ["ansi 0 on background: 2.28 (floor 3)"]
        )
        XCTAssertEqual(ThemeBrowser.contrastDetail(ThemeCatalog.theme("github-light").palette), [])
        for entry in ThemeCatalog.all {
            let findings = PaletteCheck.findings(entry.palette)
            let detail = ThemeBrowser.contrastDetail(entry.palette)

            XCTAssertEqual(detail.count, findings.count, entry.id)
            for (line, finding) in zip(detail, findings) {
                XCTAssertTrue(line.hasPrefix("\(finding.subject) on \(finding.ground): "), "\(entry.id): \(line)")
            }
        }
    }

    /// 2610.0009 S37 — the floors 3 and 4.5, each as it is written.
    func testS37TheDetailOfAFileThemeNamesItsChromeFindings() {
        var colours = ThemeFixture.draculaColours
        colours.chrome = [.bg0: 0x101010, .agent: 0xff00ff, .muted: 0x6272a4]

        let detail = ThemeBrowser.contrastDetail(ThemeFile.palette(from: colours))

        XCTAssertEqual(detail.count, 4)
        XCTAssertEqual(detail.first, "ansi 0 on background: 1.11 (floor 3)")
        for (line, fill) in zip(detail.dropFirst(), ["bg0", "bg1", "bg2"]) {
            XCTAssertTrue(line.hasPrefix("muted on \(fill): "), line)
            XCTAssertTrue(line.hasSuffix(" (floor 4.5)"), line)
        }
    }

    /// 2610.0009 S37 — the floor of the foreground.
    func testS37TheFloorOfTheForegroundIsWrittenAs7() {
        XCTAssertEqual(
            ThemeBrowser.contrastDetail(ThemeFile.palette(from: ThemeFixture.hotDogStandColours)).first {
                $0.hasPrefix("foreground")
            },
            "foreground on background: 4.20 (floor 7)"
        )
    }

    /// S62
    func testS62ABoxIsTitledForItsAppearance() {
        XCTAssertEqual(ThemeBrowser.boxTitle(for: .light), "Apply to Light")
        XCTAssertEqual(ThemeBrowser.boxTitle(for: .dark), "Apply to Dark")
    }

    /// S62 — the variants of the spec's table.
    func testS62TheCaptionSaysWhatTheThemeIs() {
        XCTAssertEqual(ThemeBrowser.caption(of: ThemeCatalog.theme("catppuccin-latte")), "light theme")
        XCTAssertEqual(ThemeBrowser.caption(of: ThemeCatalog.theme("catppuccin-mocha")), "dark theme")

        let variants = ["light", "dark", "light", "dark", "light", "dark", "light", "dark"]
        for (entry, variant) in zip(ThemeCatalog.all, variants) {
            XCTAssertTrue(ThemeBrowser.caption(of: entry).hasPrefix(variant), entry.id)
        }
    }

    // MARK: - A theme from a file (spec 2610.0009)

    /// S34
    func testS34ABoxOfAFileThemeFollowsTheRuleOfEveryTheme() {
        let breezeLight = ThemeCatalog.standard(for: .light)

        XCTAssertEqual(
            ThemeBrowser.box(shown: dracula, chosen: dracula, for: .light), ThemeBrowser.Box(isOn: true, isEnabled: true)
        )
        XCTAssertEqual(
            ThemeBrowser.box(shown: dracula, chosen: breezeLight, for: .light),
            ThemeBrowser.Box(isOn: false, isEnabled: true)
        )
        XCTAssertEqual(ThemeBrowser.toggled(shown: dracula, on: true, for: .light), dracula)
    }

    /// S34 — a file that was changed is still the chosen theme.
    func testS34ABoxComparesIds() {
        let changed = ThemeCatalog.Entry(id: dracula.id, title: dracula.title, palette: ThemeCatalog.all[0].palette)

        XCTAssertTrue(ThemeBrowser.box(shown: changed, chosen: dracula, for: .dark).isOn)
    }

    /// S35
    func testS35WithNothingChosenAFileThemeHasNoMark() {
        let marks = marks([:], in: withDracula)

        XCTAssertEqual(marks["breeze-light"], [.light])
        XCTAssertEqual(marks["breeze-dark"], [.dark])
        XCTAssertEqual(marks.values.filter(\.isEmpty).count, 7)
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S35
    func testS35AFileThemeHasBothMarksLightFirst() {
        let marks = marks([.light: "file:Dracula", .dark: "file:Dracula"], in: withDracula)

        XCTAssertEqual(marks["file:Dracula"], [.light, .dark])
        XCTAssertEqual(marks.values.filter(\.isEmpty).count, 8)
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S35
    func testS35ABuiltInThemeKeepsItsMarkBesideAFileTheme() {
        let marks = marks([.dark: "solarized-light"], in: withDracula)

        XCTAssertEqual(marks["solarized-light"], [.dark])
        XCTAssertEqual(marks["breeze-light"], [.light])
        XCTAssertEqual(marks["breeze-dark"], [])
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S35 — a file that was changed while it is the chosen theme keeps its
    /// marks: a row is compared by id, as a box is.
    func testS35AMarkComparesIds() {
        let changed = ThemeCatalog.Entry(id: dracula.id, title: dracula.title, palette: ThemeCatalog.all[0].palette)

        XCTAssertEqual(ThemeBrowser.marks(of: changed) { _ in dracula }, [.light, .dark])
    }

    /// S35 — the file is away: its appearance has the standard theme.
    func testS35AFileThatIsGoneLeavesTheMarkOnTheStandardTheme() {
        let marks = marks([.dark: "file:Gone"], in: withDracula)

        XCTAssertEqual(marks["breeze-dark"], [.dark])
        assertEachAppearanceMarksOneTheme(marks)
    }

    /// S38
    func testS38TheCaptionOfAFileThemeSaysSo() {
        let latte = ThemeCatalog.Entry(
            id: "file:Latte", title: "Latte", palette: ThemeFile.palette(from: ThemeFixture.latteColours)
        )

        XCTAssertEqual(ThemeBrowser.caption(of: dracula), "dark theme, from a file")
        XCTAssertEqual(ThemeBrowser.caption(of: latte), "light theme, from a file")
        for entry in ThemeCatalog.all {
            XCTAssertEqual(ThemeBrowser.caption(of: entry), "\(entry.variant.rawValue) theme", entry.id)
        }
    }

    /// S39 — the tooltip of the note and of the line under the list: one
    /// line for each detail, and none at all with no detail.
    func testS39ATooltipHasOneLineForEachDetail() {
        XCTAssertNil(ThemeBrowser.toolTip([]))
        XCTAssertEqual(ThemeBrowser.toolTip(["a: has no background"]), "a: has no background")
        XCTAssertEqual(ThemeBrowser.toolTip(["a: x", "b: y"]), "a: x\nb: y")
    }

    /// S39
    func testS39TheLineUnderTheListCountsTheThemesAndTheFilesNotRead() {
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 0, refused: 0), "No theme files.")
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 1, refused: 0), "1 theme from a file.")
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 5, refused: 0), "5 themes from files.")
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 0, refused: 1), "1 file was not read.")
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 5, refused: 2), "5 themes from files. 2 files were not read.")
        XCTAssertEqual(ThemeBrowser.filesNote(themes: 2, refused: 1), "2 themes from files. 1 file was not read.")
    }

    /// S40 — a file that changed is shown with its new colours.
    func testS40AShownThemeKeepsItsIdWhenTheThemesChange() {
        let changed = ThemeLibrary(files: [ThemeFixture.file("Dracula", ThemeFixture.dracula(background: "#1e1f29"))])
        let inEffect = ThemeCatalog.standard(for: .dark)

        let shown = ThemeBrowser.shown(dracula, in: changed, inEffect: inEffect)

        XCTAssertEqual(shown.id, "file:Dracula")
        XCTAssertEqual(shown.palette.terminal.background, 0x1e1f29)
    }

    /// S40
    func testS40AShownThemeWhoseFileIsGoneGivesWayToTheThemeInEffect() {
        let inEffect = ThemeCatalog.theme("github-light")

        XCTAssertEqual(ThemeBrowser.shown(dracula, in: .shipped, inEffect: inEffect), inEffect)
    }

    /// S40
    func testS40AShownBuiltInThemeStays() {
        let githubDark = ThemeCatalog.theme("github-dark")

        for library in [ThemeLibrary.shipped, withDracula] {
            XCTAssertEqual(
                ThemeBrowser.shown(githubDark, in: library, inEffect: ThemeCatalog.standard(for: .dark)), githubDark
            )
        }
    }
}
