import XCTest
@testable import TarmacKit

final class OverlayStackTests: XCTestCase {
    func testTheZIndexesAreTheStylesheets() {
        XCTAssertEqual(OverlayStack.hints.zIndex, 40)
        XCTAssertEqual(OverlayStack.zoomControl.zIndex, 50)
        XCTAssertEqual(OverlayStack.minimap.zIndex, 50)
        XCTAssertEqual(OverlayStack.toasts.zIndex, 70)
        XCTAssertEqual(OverlayStack.switcher.zIndex, 80)
        XCTAssertEqual(OverlayStack.restoreCard.zIndex, 90)
        XCTAssertEqual(OverlayStack.inbox.zIndex, 60)
    }

    /// #358: the card that takes the first key is drawn over everything.
    func testThePillsAreUnderTheCornerControlsAndTheRestoreCardIsOverEverything() {
        XCTAssertEqual(
            OverlayStack.backToFront, [.hints, .zoomControl, .minimap, .inbox, .toasts, .switcher, .restoreCard]
        )
    }

    /// The pills keep clear of the corner controls drawn over them. The inbox
    /// narrows the pills' area instead, and the switcher and the restore card
    /// cover the whole board.
    func testThePillsKeepClearOfTheZoomControlTheMinimapAndTheToasts() {
        XCTAssertEqual(OverlayStack.pillChrome, [.zoomControl, .minimap, .toasts])
        for layer in OverlayStack.pillChrome { XCTAssertGreaterThan(layer.zIndex, OverlayStack.hints.zIndex) }
    }

    func testEveryOverlayIsStackedOnce() {
        XCTAssertEqual(OverlayStack.backToFront.count, OverlayStack.allCases.count)
        XCTAssertEqual(Set(OverlayStack.backToFront), Set(OverlayStack.allCases))
    }
}
