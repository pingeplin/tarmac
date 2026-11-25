import XCTest

@testable import TarmacKit

/// 2610.0007, 2611.0025: the sections of the Settings window.
final class SettingsPaneTests: XCTestCase {
    /// "Settings panes are Fonts and Theme"; 2611.0025 "Settings panes list Fonts Theme Documents"
    func testS19ThePanesInOrderAndTitled() {
        XCTAssertEqual(SettingsPane.allCases, [.fonts, .theme, .documents])
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Fonts", "Theme", "Documents"])
    }
}
