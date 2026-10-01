import XCTest
@testable import TarmacKit

/// How a terminal card's mouse selection coexists with a program that tracks the
/// mouse (#154).
final class TermMouseSelectTests: XCTestCase {
    private let trackingModes: [TermMouseSelect.TrackingMode] = [.x10, .vt200, .drag, .any]

    func testKeepsTheShellBehaviourWhenTheProgramDoesNotTrackTheMouse() {
        XCTAssertEqual(
            TermMouseSelect.options(for: .none),
            TermMouseSelect.Options(optionDragForcesSelection: false, optionClickMovesCursor: true)
        )
    }

    func testForcesOptionDragSelectionAndSendsNoCursorKeysWhileTheProgramTracksTheMouse() {
        for mode in trackingModes {
            XCTAssertEqual(
                TermMouseSelect.options(for: mode),
                TermMouseSelect.Options(optionDragForcesSelection: true, optionClickMovesCursor: false),
                "\(mode)"
            )
        }
    }

    func testSwallowsAButtonlessMoveWhileASelectionIsShownUnderAnyEventTracking() {
        XCTAssertTrue(TermMouseSelect.swallowsHover(mode: .any, buttons: 0, hasSelection: true))
    }

    func testLetsMovesThroughUnderTrackingModesThatSendNoHoverReports() {
        for mode in [TermMouseSelect.TrackingMode.none, .x10, .vt200, .drag] {
            XCTAssertFalse(TermMouseSelect.swallowsHover(mode: mode, buttons: 0, hasSelection: true), "\(mode)")
        }
    }

    func testLetsMovesThroughWithoutASelectionOrWhileAButtonIsHeld() {
        XCTAssertFalse(TermMouseSelect.swallowsHover(mode: .any, buttons: 0, hasSelection: false))
        XCTAssertFalse(TermMouseSelect.swallowsHover(mode: .any, buttons: 1, hasSelection: true))
        XCTAssertFalse(TermMouseSelect.swallowsHover(mode: .any, buttons: 2, hasSelection: true))
    }
}
