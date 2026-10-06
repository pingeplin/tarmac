import XCTest
@testable import TarmacKit

/// 2610.0007: what the user can choose, and the theme each choice puts in
/// effect.
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
}
