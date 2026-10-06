import XCTest
@testable import TarmacKit

/// 2610.0008: the rules of the Theme pane's list and showcase.
final class ThemeBrowserTests: XCTestCase {
    private func theme(_ id: String) -> ThemeCatalog.Entry {
        guard let entry = ThemeCatalog.all.first(where: { $0.id == id }) else { fatalError("no theme \(id)") }
        return entry
    }

    private func box(_ shown: String, chosen: String, for variant: ThemeVariant) -> ThemeBrowser.Box {
        ThemeBrowser.box(shown: theme(shown), chosen: theme(chosen), for: variant)
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
        ThemeBrowser.toggled(shown: theme(shown), on: on, for: variant).id
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

    private func marks(_ themes: [ThemeVariant: String]) -> [String: [ThemeVariant]] {
        Dictionary(uniqueKeysWithValues: ThemeCatalog.all.map { ($0.id, ThemeBrowser.marks(of: $0, themes: themes)) })
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
            ThemeBrowser.contrastNote(theme("github-light").palette),
            "Every terminal colour passes the contrast floors."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(theme("github-dark").palette),
            "1 terminal colour has low contrast on the background."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(theme("catppuccin-latte").palette),
            "9 terminal colours have low contrast on the background."
        )
        XCTAssertEqual(
            ThemeBrowser.contrastNote(theme("solarized-light").palette),
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

    /// S61 — a note that counts every finding fails here.
    func testS61AChromeFindingIsNotCounted() {
        let breeze = theme("breeze-light").palette
        let palette = breeze.changed(agent: breeze.bg0)
        let findings = PaletteCheck.findings(palette)
        XCTAssertEqual(findings.map(\.part), [.chrome, .chrome, .chrome])
        XCTAssertEqual(findings.map(\.subject), ["agent", "agent", "agent"])
        XCTAssertEqual(findings.map(\.ground), ["bg0", "bg1", "bg2"])

        XCTAssertEqual(ThemeBrowser.contrastNote(palette), "Every terminal colour passes the contrast floors.")
    }

    /// S62
    func testS62ABoxIsTitledForItsAppearance() {
        XCTAssertEqual(ThemeBrowser.boxTitle(for: .light), "Apply to Light")
        XCTAssertEqual(ThemeBrowser.boxTitle(for: .dark), "Apply to Dark")
    }

    /// S62 — the variants of the spec's table.
    func testS62TheCaptionSaysWhatTheThemeIs() {
        XCTAssertEqual(ThemeBrowser.caption(of: theme("catppuccin-latte")), "light theme")
        XCTAssertEqual(ThemeBrowser.caption(of: theme("catppuccin-mocha")), "dark theme")

        let variants = ["light", "dark", "light", "dark", "light", "dark", "light", "dark"]
        for (entry, variant) in zip(ThemeCatalog.all, variants) {
            XCTAssertTrue(ThemeBrowser.caption(of: entry).hasPrefix(variant), entry.id)
        }
    }
}
