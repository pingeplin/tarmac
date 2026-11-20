import XCTest
import TarmacKit

/// Issue #438: a dev app shows its own Dock icon; a shipped app keeps the bundle's.
final class DevIconTests: XCTestCase {
    func testADevLabelAndAnIconPathYieldThePath() {
        XCTAssertEqual(DevIcon.path(devLabel: "438-dev-icon", iconPath: "/r/Tarmac-dev-1024.png"), "/r/Tarmac-dev-1024.png")
    }

    func testNoDevLabelYieldsNoIconEvenWithAPath() {
        XCTAssertNil(DevIcon.path(devLabel: nil, iconPath: "/r/Tarmac-dev-1024.png"))
    }

    func testABlankDevLabelYieldsNoIconAsItYieldsNoTitleSuffix() {
        XCTAssertNil(DevIcon.path(devLabel: "  \t ", iconPath: "/r/Tarmac-dev-1024.png"))
    }

    func testADevLabelWithNoOrAnEmptyPathYieldsNoIcon() {
        XCTAssertNil(DevIcon.path(devLabel: "438-dev-icon", iconPath: nil))
        XCTAssertNil(DevIcon.path(devLabel: "438-dev-icon", iconPath: ""))
    }
}
