import XCTest
@testable import TarmacKit

/// 2610.0008: the themes Tarmac has, which of them an appearance is offered,
/// and the one in effect.
final class ThemeCatalogTests: XCTestCase {
    /// S1 — the order of the pop-ups: Breeze first, then by name.
    func testS1TheCatalogueHasTheEightThemesInPopUpOrder() {
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

    /// S2 — a light theme is offered for the light appearance alone.
    func testS2AnAppearanceIsOfferedTheThemesOfItsVariant() {
        let light = ThemeCatalog.offered(for: .light).map(\.id)
        let dark = ThemeCatalog.offered(for: .dark).map(\.id)

        XCTAssertEqual(light, ["breeze-light", "catppuccin-latte", "github-light", "solarized-light"])
        XCTAssertEqual(dark, ["breeze-dark", "catppuccin-mocha", "github-dark", "solarized-dark"])
        XCTAssertEqual(Set(light + dark), Set(ThemeCatalog.all.map(\.id)))
        XCTAssertTrue(Set(light).isDisjoint(with: dark))
    }

    /// S3 — nothing changes for a user who chooses nothing.
    func testS3TheStandardThemesAreBreeze() {
        XCTAssertEqual(ThemeCatalog.standard(for: .light).id, "breeze-light")
        XCTAssertEqual(ThemeCatalog.standard(for: .dark).id, "breeze-dark")
    }

    /// S4
    func testS4AnOfferedIdNamesItsTheme() {
        XCTAssertEqual(ThemeCatalog.entry("solarized-light", for: .light).id, "solarized-light")
        XCTAssertEqual(ThemeCatalog.entry("github-dark", for: .dark).id, "github-dark")
    }

    /// S4 — no id, an unknown one, one of the other appearance and one in
    /// another letter case.
    func testS4AnyOtherIdNamesTheStandardTheme() {
        for id in [nil, "sepia", "catppuccin-mocha", "GitHub-Light"] {
            XCTAssertEqual(ThemeCatalog.entry(id, for: .light).id, "breeze-light", id ?? "nil")
        }
        XCTAssertEqual(ThemeCatalog.entry("solarized-light", for: .dark).id, "breeze-dark")
    }

    private func inEffect(_ choice: ThemeChoice, _ themes: [ThemeVariant: String], systemIsDark: Bool) -> String {
        ThemeCatalog.inEffect(choice: choice, themes: themes, systemIsDark: systemIsDark).id
    }

    /// S5
    func testS5AutoIsTheThemeChosenForTheSystemsAppearance() {
        let themes: [ThemeVariant: String] = [.light: "solarized-light", .dark: "catppuccin-mocha"]

        XCTAssertEqual(inEffect(.auto, themes, systemIsDark: true), "catppuccin-mocha")
        XCTAssertEqual(inEffect(.auto, themes, systemIsDark: false), "solarized-light")
    }

    /// S5
    func testS5LightAndDarkAreTheirOwnThemeWhateverTheSystem() {
        let themes: [ThemeVariant: String] = [.light: "solarized-light", .dark: "catppuccin-mocha"]

        for systemIsDark in [true, false] {
            XCTAssertEqual(inEffect(.light, themes, systemIsDark: systemIsDark), "solarized-light")
            XCTAssertEqual(inEffect(.dark, themes, systemIsDark: systemIsDark), "catppuccin-mocha")
        }
    }

    /// S5
    func testS5NoThemeOrAnUnknownOneIsBreeze() {
        XCTAssertEqual(inEffect(.dark, [:], systemIsDark: false), "breeze-dark")
        XCTAssertEqual(inEffect(.light, [:], systemIsDark: true), "breeze-light")
        XCTAssertEqual(inEffect(.dark, [.dark: "sepia"], systemIsDark: true), "breeze-dark")
    }
}
