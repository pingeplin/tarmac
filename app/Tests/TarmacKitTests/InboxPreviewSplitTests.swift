import XCTest
@testable import TarmacKit

/// Spec 2611.0018 D7: the split between the inbox list and the preview pane.
final class InboxPreviewSplitTests: XCTestCase {
    private typealias Split = InboxPreviewSplit

    func testS11TheShownHeightIsTheWantedOneWithinItsBounds() {
        XCTAssertEqual(Split.shown(wanted: nil, room: 600, scale: 1), 236)
        XCTAssertEqual(Split.shown(wanted: 100, room: 600, scale: 1), 100)
        XCTAssertEqual(Split.shown(wanted: 30, room: 600, scale: 1), 72)
        XCTAssertEqual(Split.shown(wanted: 560, room: 600, scale: 1), 474)
    }

    func testS12TheMinimumWinsOverTheListsRoom() {
        XCTAssertEqual(Split.shown(wanted: 236, room: 150, scale: 1), 72)
        XCTAssertEqual(Split.shown(wanted: 236, room: 40, scale: 1), 72)
    }

    func testS13TheBoundsFollowTheInterfaceSizeAndTheResultIsAWholePoint() {
        XCTAssertEqual(Split.shown(wanted: nil, room: 800, scale: 1.25), 295)
        XCTAssertEqual(Split.shown(wanted: 30, room: 800, scale: 1.25), 90)
        XCTAssertEqual(Split.shown(wanted: 560, room: 800, scale: 1.25), 643)
    }

    func testS14AStepOrADragMovesTheWantedHeightWithinTheBounds() {
        XCTAssertEqual(Split.stepped(wanted: nil, steps: 1, room: 600, scale: 1), 260)
        XCTAssertEqual(Split.stepped(wanted: nil, steps: -10, room: 600, scale: 1), 72)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 40, room: 600, scale: 1), 276)
        XCTAssertEqual(Split.dragged(wanted: 236, by: -40, room: 600, scale: 1), 196)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 1000, room: 600, scale: 1), 474)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 40, room: 1200, scale: 2), 256)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 5000, room: 3000, scale: 1), 2000)
    }

    func testS29AStepOrADragStartsFromTheShownHeight() {
        XCTAssertEqual(Split.stepped(wanted: 400, steps: -1, room: 300, scale: 1), 150)
        XCTAssertEqual(Split.dragged(wanted: 400, by: -10, room: 300, scale: 1), 164)
    }

    func testS30AnActionThatShowsNoChangeKeepsTheWantedHeight() {
        XCTAssertEqual(Split.dragged(wanted: 400, by: 0, room: 300, scale: 1), 400)
        XCTAssertEqual(Split.stepped(wanted: 400, steps: 1, room: 300, scale: 1), 400)
        XCTAssertNil(Split.dragged(wanted: nil, by: 0, room: 600, scale: 1))
        XCTAssertEqual(Split.stepped(wanted: 72, steps: -1, room: 600, scale: 1), 72)
    }
}
