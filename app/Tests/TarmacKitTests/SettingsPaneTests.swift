import XCTest
@testable import TarmacKit

/// 2610.0007: the sections of the Settings window.
final class SettingsPaneTests: XCTestCase {
    /// S19
    func testS19ThePanesAreFontsThenThemeAndTitled() {
        XCTAssertEqual(SettingsPane.allCases, [.fonts, .theme])
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Fonts", "Theme"])
    }
}
