import XCTest
@testable import TarmacKit

final class OverlayStackTests: XCTestCase {
    func testTheZIndexesAreTheStylesheets() {
        XCTAssertEqual(OverlayStack.hints.zIndex, 40)
        XCTAssertEqual(OverlayStack.zoomControl.zIndex, 50)
        XCTAssertEqual(OverlayStack.minimap.zIndex, 50)
        XCTAssertEqual(OverlayStack.toasts.zIndex, 70)
        XCTAssertEqual(OverlayStack.switcher.zIndex, 80)
        XCTAssertEqual(OverlayStack.cycleHUD.zIndex, 90)
    }

    func testThePillsAreUnderTheCornerControlsAndTheCycleHUDIsOverTheSwitcher() {
        XCTAssertEqual(
            OverlayStack.backToFront,
            [.hints, .zoomControl, .minimap, .toasts, .switcher, .cycleHUD]
        )
    }

    func testEveryOverlayIsStackedOnce() {
        XCTAssertEqual(OverlayStack.backToFront.count, OverlayStack.allCases.count)
        XCTAssertEqual(Set(OverlayStack.backToFront), Set(OverlayStack.allCases))
    }
}
