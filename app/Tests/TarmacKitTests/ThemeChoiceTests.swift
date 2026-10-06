import XCTest
@testable import TarmacKit

/// 2610.0007: the appearance the user can choose, and the variant each choice
/// puts in effect.
final class ThemeChoiceTests: XCTestCase {
    /// S1 — the tiles, in their order, and the key the choice is saved under.
    func testS1TheChoicesAreAutoLightAndDarkInTileOrder() {
        XCTAssertEqual(ThemeChoice.allCases, [.auto, .light, .dark])
        XCTAssertEqual(ThemeChoice.allCases.map(\.rawValue), ["auto", "light", "dark"])
        XCTAssertEqual(ThemeChoice.allCases.map(\.title), ["Auto", "Light", "Dark"])
        XCTAssertEqual(ThemeChoice.standard, .dark)
        XCTAssertEqual(ThemeChoice.prefsKey, "theme")
    }

    /// S2
    func testS2LightAndDarkDoNotFollowTheSystem() {
        for systemIsDark in [true, false] {
            XCTAssertEqual(ThemeChoice.light.inEffect(systemIsDark: systemIsDark), .light, "\(systemIsDark)")
            XCTAssertEqual(ThemeChoice.dark.inEffect(systemIsDark: systemIsDark), .dark, "\(systemIsDark)")
        }
    }

    /// S2
    func testS2AutoIsTheVariantOfTheSystem() {
        XCTAssertEqual(ThemeChoice.auto.inEffect(systemIsDark: true), .dark)
        XCTAssertEqual(ThemeChoice.auto.inEffect(systemIsDark: false), .light)
    }

    /// 2610.0008 S6 — the key and the row of the theme chosen for an appearance.
    func testAnAppearanceHasAKeyAndARowForItsTheme() {
        XCTAssertEqual(ThemeVariant.allCases, [.light, .dark])
        XCTAssertEqual(ThemeVariant.allCases.map(\.prefsKey), ["theme_light", "theme_dark"])
        XCTAssertEqual(ThemeVariant.allCases.map(\.rowTitle), ["Light theme", "Dark theme"])
    }

    /// A tile's picture shows each variant its choice can put in effect, light
    /// first.
    func testATilePicturesEachVariantItsChoiceCanGiveLightFirst() {
        XCTAssertEqual(ThemeChoice.auto.pictured, [.light, .dark])
        XCTAssertEqual(ThemeChoice.light.pictured, [.light])
        XCTAssertEqual(ThemeChoice.dark.pictured, [.dark])
    }
}
