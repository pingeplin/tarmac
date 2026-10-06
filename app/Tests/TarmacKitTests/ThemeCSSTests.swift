import XCTest
@testable import TarmacKit

/// 2610.0007: the declarations a doc page and the HTML card host page are
/// given for a theme.
final class ThemeCSSTests: XCTestCase {
    private let names = ["--bg1", "--bg2", "--term-bg", "--text", "--prose-text", "--agent", "--agent-dim", "color-scheme"]

    /// S15
    func testS15TheLightDeclarationsAreTheEightOfTheContractInOrder() {
        let properties = ThemeCSS.properties(.light)

        XCTAssertEqual(properties.map(\.name), names)
        XCTAssertEqual(
            properties.map(\.value),
            ["#eff0f1", "#dee0e2", "#fcfcfc", "#232629", "#31363b", "#12846e", "rgba(18, 132, 110, 0.16)", "light"]
        )
    }

    /// S15
    func testS15TheDarkDeclarationsAreThePageOfToday() {
        let properties = ThemeCSS.properties(.dark)

        XCTAssertEqual(properties.map(\.name), names)
        XCTAssertEqual(
            properties.map(\.value),
            ["#2b3036", "#353b41", "#31363b", "#eff0f1", "#ced3d7", "#1abc9c", "rgba(26, 188, 156, 0.16)", "dark"]
        )
    }

    /// S16
    func testS16TheMarkerBecomesEveryDeclaration() {
        let page = ThemeCSS.page(":root { /*tarmac-theme*/ --zoom: 1; }", .light)

        XCTAssertFalse(page.contains("/*tarmac-theme*/"))
        for declaration in [
            "--bg1: #eff0f1;", "--bg2: #dee0e2;", "--term-bg: #fcfcfc;", "--text: #232629;", "--prose-text: #31363b;",
            "--agent: #12846e;", "--agent-dim: rgba(18, 132, 110, 0.16);", "color-scheme: light;",
        ] {
            XCTAssertTrue(page.contains(declaration), declaration)
        }
        XCTAssertTrue(page.hasPrefix(":root { "))
        XCTAssertTrue(page.hasSuffix(" --zoom: 1; }"))
    }

    /// S16 — the host page gets its backdrop and no `color-scheme`.
    func testS16TheBackdropMarkerBecomesTheBackdropAlone() {
        XCTAssertEqual(ThemeCSS.page(":root { /*tarmac-backdrop*/ }", .light), ":root { --bg1: #eff0f1; }")
        XCTAssertEqual(ThemeCSS.page(":root { /*tarmac-backdrop*/ }", .dark), ":root { --bg1: #2b3036; }")
    }

    /// S42 — a marker is a place only when the template holds it once.
    func testS42ATemplateWithNoMarkerOrOneTwiceComesBackUnchanged() {
        let templates = [
            ":root { --zoom: 1; }",
            ":root { /*tarmac-theme*/ } body { /*tarmac-theme*/ }",
            ":root { /*tarmac-backdrop*/ } body { /*tarmac-backdrop*/ }",
        ]
        for template in templates {
            XCTAssertEqual(ThemeCSS.page(template, .light), template)
        }
    }

    /// S42 — each marker is counted on its own.
    func testS42AMarkerHeldOnceIsReplacedBesideOneHeldTwice() {
        XCTAssertEqual(
            ThemeCSS.page("a { /*tarmac-theme*/ } b { /*tarmac-theme*/ } :root { /*tarmac-backdrop*/ }", .light),
            "a { /*tarmac-theme*/ } b { /*tarmac-theme*/ } :root { --bg1: #eff0f1; }"
        )
    }
}
