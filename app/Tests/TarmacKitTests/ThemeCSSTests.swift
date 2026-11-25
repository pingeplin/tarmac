import XCTest

@testable import TarmacKit

/// 2610.0007: the declarations a doc page and the HTML card host page are
/// given for a theme. The cases marked 2610.0008 are that spec's.
final class ThemeCSSTests: XCTestCase {
    private let light = ThemeCatalog.standard(for: .light).palette
    private let dark = ThemeCatalog.standard(for: .dark).palette

    private let names = [
        "--bg1", "--bg2", "--line", "--muted", "--bg3", "--faint", "--term-bg", "--text", "--prose-text", "--agent",
        "--agent-dim",
        "color-scheme",
    ]

    /// "Theme CSS properties for each variant"; 2611.0022 "Theme gives bg3 and faint tokens" adds `--bg3` and `--faint`.
    func testTheLightDeclarationsAreTheTwelveOfTheContractInOrder() {
        let properties = ThemeCSS.properties(light)

        XCTAssertEqual(properties.map(\.name), names)
        XCTAssertEqual(
            properties.map(\.value),
            [
                "#eff0f1", "#dee0e2", "#b4b9be", "#535d66", "#cdd1d5", "#707d8a", "#fcfcfc", "#232629", "#31363b",
                "#12846e",
                "rgba(18, 132, 110, 0.16)", "light",
            ]
        )
    }

    /// "Theme CSS properties for each variant"
    func testTheDarkDeclarationsAreThePageOfToday() {
        let properties = ThemeCSS.properties(dark)

        XCTAssertEqual(properties.map(\.name), names)
        XCTAssertEqual(
            properties.map(\.value),
            [
                "#2b3036", "#353b41", "#474e55", "#b9bfc4", "#3e444b", "#7f8c8d", "#31363b", "#eff0f1", "#ced3d7",
                "#1abc9c",
                "rgba(26, 188, 156, 0.16)", "dark",
            ]
        )
    }

    /// "Theme markers are replaced in a page"
    func testTheMarkerBecomesEveryDeclaration() {
        let page = ThemeCSS.page(":root { /*tarmac-theme*/ --zoom: 1; }", light)

        XCTAssertFalse(page.contains("/*tarmac-theme*/"))
        for declaration in [
            "--bg1: #eff0f1;", "--bg2: #dee0e2;", "--line: #b4b9be;", "--muted: #535d66;", "--bg3: #cdd1d5;",
            "--faint: #707d8a;", "--term-bg: #fcfcfc;",
            "--text: #232629;", "--prose-text: #31363b;", "--agent: #12846e;", "--agent-dim: rgba(18, 132, 110, 0.16);",
            "color-scheme: light;",
        ] {
            XCTAssertTrue(page.contains(declaration), declaration)
        }
        XCTAssertTrue(page.hasPrefix(":root { "))
        XCTAssertTrue(page.hasSuffix(" --zoom: 1; }"))
    }

    /// "Theme markers are replaced in a page" — the host page gets its backdrop and no `color-scheme`.
    func testTheBackdropMarkerBecomesTheBackdropAlone() {
        XCTAssertEqual(ThemeCSS.page(":root { /*tarmac-backdrop*/ }", light), ":root { --bg1: #eff0f1; }")
        XCTAssertEqual(ThemeCSS.page(":root { /*tarmac-backdrop*/ }", dark), ":root { --bg1: #2b3036; }")
    }

    /// The pair a loaded host page is given on a change is the one `page`
    /// writes into it.
    func testTheBackdropIsThePairTheBackdropMarkerBecomes() {
        for palette in [light, dark] {
            let backdrop = ThemeCSS.backdrop(palette)
            XCTAssertEqual(
                ThemeCSS.page("/*tarmac-backdrop*/", palette), "\(backdrop.name): \(backdrop.value);"
            )
        }
        XCTAssertEqual(ThemeCSS.backdrop(light).name, "--bg1")
        XCTAssertEqual(ThemeCSS.backdrop(light).value, "#eff0f1")
        XCTAssertEqual(ThemeCSS.backdrop(dark).value, "#2b3036")
    }

    /// 2610.0008 "Theme CSS properties match the palette" — the pairs are those of the palette given, whatever
    /// theme it is.
    func testTheDeclarationsAreThoseOfThePaletteGiven() {
        let latte = ThemeCSS.properties(ThemeCatalog.theme("catppuccin-latte").palette)

        XCTAssertEqual(latte.map(\.name), names)
        XCTAssertEqual(
            latte.map(\.value),
            [
                "#e6e9ef", "#ccd0da", "#acb0be", "#55586e", "#bcc0cc", "#7c7f93", "#eff1f5", "#4c4f69", "#4c4f69",
                "#148187",
                "rgba(20, 129, 135, 0.16)", "light",
            ]
        )

        let mocha = ThemeCSS.properties(ThemeCatalog.theme("catppuccin-mocha").palette)
        XCTAssertEqual(mocha.first?.value, "#181825")
        XCTAssertEqual(mocha.last?.value, "dark")
    }

    /// 2610.0008 "Page template takes backdrop and theme markers" — the first template holds no theme marker, so its
    /// `--bg1` comes from the backdrop marker alone.
    func testTheBackdropAndThePageAreThoseOfThePaletteGiven() {
        let palette = ThemeCatalog.theme("github-dark").palette

        XCTAssertEqual(ThemeCSS.backdrop(palette).name, "--bg1")
        XCTAssertEqual(ThemeCSS.backdrop(palette).value, "#070a10")
        XCTAssertEqual(ThemeCSS.page(":root { /*tarmac-backdrop*/ }", palette), ":root { --bg1: #070a10; }")
        let page = ThemeCSS.page(":root { /*tarmac-theme*/ }", palette)
        XCTAssertTrue(page.contains("--term-bg: #0d1117;"))
        XCTAssertTrue(page.contains("color-scheme: dark;"))
    }

    /// "Page with wrong markers comes back unchanged" — a marker is a place only when the template holds it once.
    func testATemplateWithNoMarkerOrOneTwiceComesBackUnchanged() {
        let templates = [
            ":root { --zoom: 1; }",
            ":root { /*tarmac-theme*/ } body { /*tarmac-theme*/ }",
            ":root { /*tarmac-backdrop*/ } body { /*tarmac-backdrop*/ }",
        ]
        for template in templates {
            XCTAssertEqual(ThemeCSS.page(template, light), template)
        }
    }

    /// "Page with wrong markers comes back unchanged" — each marker is counted on its own.
    func testAMarkerHeldOnceIsReplacedBesideOneHeldTwice() {
        XCTAssertEqual(
            ThemeCSS.page("a { /*tarmac-theme*/ } b { /*tarmac-theme*/ } :root { /*tarmac-backdrop*/ }", light),
            "a { /*tarmac-theme*/ } b { /*tarmac-theme*/ } :root { --bg1: #eff0f1; }"
        )
    }
}
