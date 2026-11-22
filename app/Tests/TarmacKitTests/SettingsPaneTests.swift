import XCTest

@testable import TarmacKit

/// 2610.0007, 2611.0025: the sections of the Settings window.
final class SettingsPaneTests: XCTestCase {
    /// S19; 2611.0025 S1
    func testS19ThePanesInOrderAndTitled() {
        XCTAssertEqual(SettingsPane.allCases, [.fonts, .theme, .documents])
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["Fonts", "Theme", "Documents"])
    }
}
