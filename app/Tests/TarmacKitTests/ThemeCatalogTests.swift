import XCTest
@testable import TarmacKit

/// 2610.0008: the themes Tarmac has, the theme an id names for an appearance,
/// and the one in effect.
final class ThemeCatalogTests: XCTestCase {
    /// S1 — the order of the list: Breeze first, then by name.
    func testS1TheCatalogueHasTheEightThemesInListOrder() {
        XCTAssertEqual(
            ThemeCatalog.all.map(\.id),
            [
                "breeze-light", "breeze-dark", "catppuccin-latte", "catppuccin-mocha", "github-light", "github-dark",
                "solarized-light", "solarized-dark",
            ]
        )
        XCTAssertEqual(
            ThemeCatalog.all.map(\.title),
            [
                "Breeze Light", "Breeze Dark", "Catppuccin Latte", "Catppuccin Mocha", "GitHub Light", "GitHub Dark",
                "Solarized Light", "Solarized Dark",
            ]
        )
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.id)).count, 8)
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.title)).count, 8)
    }

    /// S2 — any theme for any appearance: the sixteen pairs.
    func testS2EachThemeCanBeChosenForEachAppearance() {
        var pairs = 0
        for theme in ThemeCatalog.all {
            for variant in ThemeVariant.allCases {
                XCTAssertEqual(ThemeCatalog.entry(theme.id, for: variant), theme, "\(theme.id) \(variant.rawValue)")
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 16)
    }

    /// S3 — nothing changes for a user who chooses nothing.
    func testS3TheStandardThemesAreBreeze() {
        XCTAssertEqual(ThemeCatalog.standard(for: .light).id, "breeze-light")
        XCTAssertEqual(ThemeCatalog.standard(for: .dark).id, "breeze-dark")
    }

    /// S4 — a theme of the other variant, and the standard theme of the
    /// other appearance.
    func testS4AnIdNamesItsThemeWhateverTheAppearance() {
        XCTAssertEqual(ThemeCatalog.entry("catppuccin-mocha", for: .light).id, "catppuccin-mocha")
        XCTAssertEqual(ThemeCatalog.entry("solarized-light", for: .dark).id, "solarized-light")
        XCTAssertEqual(ThemeCatalog.entry("breeze-dark", for: .light).id, "breeze-dark")
    }

    /// S4 — no id, an unknown one, one in another letter case and an empty
    /// one.
    func testS4AnIdNoThemeHasNamesTheStandardThemeOfTheAppearance() {
        for id in [nil, "sepia", "GitHub-Light", ""] {
            XCTAssertEqual(ThemeCatalog.entry(id, for: .light).id, "breeze-light", id ?? "nil")
            XCTAssertEqual(ThemeCatalog.entry(id, for: .dark).id, "breeze-dark", id ?? "nil")
        }
    }

    /// S21, S22 — the rule of the file's two keys: Breeze Dark is saved for
    /// Light, and Breeze Light is not.
    func testS21AnIdIsSavedOnlyForAThemeThatIsNotTheStandardOfItsAppearance() {
        XCTAssertEqual(ThemeCatalog.saved("catppuccin-mocha", for: .light), "catppuccin-mocha")
        XCTAssertEqual(ThemeCatalog.saved("breeze-dark", for: .light), "breeze-dark")
        XCTAssertEqual(ThemeCatalog.saved("breeze-light", for: .dark), "breeze-light")
        XCTAssertNil(ThemeCatalog.saved("breeze-light", for: .light))
        XCTAssertNil(ThemeCatalog.saved("breeze-dark", for: .dark))
        for id in [nil, "sepia", "GitHub-Light", ""] {
            XCTAssertNil(ThemeCatalog.saved(id, for: .light), id ?? "nil")
        }
    }

    private func inEffect(_ choice: ThemeChoice, _ themes: [ThemeVariant: String], systemIsDark: Bool) -> String {
        ThemeCatalog.inEffect(choice: choice, themes: themes, systemIsDark: systemIsDark).id
    }

    /// A dark theme for Light and a light theme for Dark, so that a rule
    /// which gives an appearance a theme of its own variant fails.
    private let crossed: [ThemeVariant: String] = [.light: "catppuccin-mocha", .dark: "solarized-light"]

    /// S5
    func testS5AutoIsTheThemeChosenForTheSystemsAppearance() {
        XCTAssertEqual(inEffect(.auto, crossed, systemIsDark: true), "solarized-light")
        XCTAssertEqual(inEffect(.auto, crossed, systemIsDark: false), "catppuccin-mocha")
    }

    /// S5
    func testS5LightAndDarkAreTheirOwnThemeWhateverTheSystem() {
        for systemIsDark in [true, false] {
            XCTAssertEqual(inEffect(.light, crossed, systemIsDark: systemIsDark), "catppuccin-mocha")
            XCTAssertEqual(inEffect(.dark, crossed, systemIsDark: systemIsDark), "solarized-light")
        }
    }

    /// S5
    func testS5OneThemeForBothAppearancesIsInEffectUnderEveryChoice() {
        let both: [ThemeVariant: String] = [.light: "github-dark", .dark: "github-dark"]

        for choice in ThemeChoice.allCases {
            for systemIsDark in [true, false] {
                XCTAssertEqual(inEffect(choice, both, systemIsDark: systemIsDark), "github-dark", choice.rawValue)
            }
        }
    }

    /// S5
    func testS5NoThemeOrAnUnknownOneIsBreeze() {
        XCTAssertEqual(inEffect(.dark, [:], systemIsDark: false), "breeze-dark")
        XCTAssertEqual(inEffect(.light, [:], systemIsDark: true), "breeze-light")
        XCTAssertEqual(inEffect(.dark, [.dark: "sepia"], systemIsDark: true), "breeze-dark")
    }
}
