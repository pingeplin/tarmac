import XCTest

@testable import TarmacKit

/// Spec 2611.0018 D7: the split between the inbox list and the preview pane.
final class InboxPreviewSplitTests: XCTestCase {
    private typealias Split = InboxPreviewSplit

    /// "Shown height follows wanted height and room".
    func testTheShownHeightIsTheWantedOneWithinItsBounds() {
        XCTAssertEqual(Split.shown(wanted: nil, room: 600, scale: 1), 236)
        XCTAssertEqual(Split.shown(wanted: 100, room: 600, scale: 1), 100)
        XCTAssertEqual(Split.shown(wanted: 30, room: 600, scale: 1), 72)
        XCTAssertEqual(Split.shown(wanted: 560, room: 600, scale: 1), 474)
    }

    /// "Small room keeps the minimum height".
    func testTheMinimumWinsOverTheListsRoom() {
        XCTAssertEqual(Split.shown(wanted: 236, room: 150, scale: 1), 72)
        XCTAssertEqual(Split.shown(wanted: 236, room: 40, scale: 1), 72)
    }

    /// "Display scale changes shown height".
    func testTheBoundsFollowTheInterfaceSizeAndTheResultIsAWholePoint() {
        XCTAssertEqual(Split.shown(wanted: nil, room: 800, scale: 1.25), 295)
        XCTAssertEqual(Split.shown(wanted: 30, room: 800, scale: 1.25), 90)
        XCTAssertEqual(Split.shown(wanted: 560, room: 800, scale: 1.25), 643)
    }

    /// "Steps and drags change the height".
    func testAStepOrADragMovesTheWantedHeightWithinTheBounds() {
        XCTAssertEqual(Split.stepped(wanted: nil, steps: 1, room: 600, scale: 1), 260)
        XCTAssertEqual(Split.stepped(wanted: nil, steps: -10, room: 600, scale: 1), 72)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 40, room: 600, scale: 1), 276)
        XCTAssertEqual(Split.dragged(wanted: 236, by: -40, room: 600, scale: 1), 196)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 1000, room: 600, scale: 1), 474)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 40, room: 1200, scale: 2), 256)
        XCTAssertEqual(Split.dragged(wanted: 236, by: 5000, room: 3000, scale: 1), 2000)
    }

    func testTheBoundsOfAStepOrADragAreInDesignPoints() {
        XCTAssertEqual(Split.dragged(wanted: 100, by: 400, room: 600, scale: 2), 174)
        XCTAssertEqual(Split.stepped(wanted: 160, steps: 1, room: 600, scale: 2), 174)
    }

    func testTheShownHeightRoundsToTheNearestPoint() {
        XCTAssertEqual(Split.shown(wanted: 100, room: 800, scale: 1.1), 110)
        XCTAssertEqual(Split.shown(wanted: 101, room: 800, scale: 1.25), 126)
    }

    /// "Steps and drags start from the shown height".
    func testAStepOrADragStartsFromTheShownHeight() {
        XCTAssertEqual(Split.stepped(wanted: 400, steps: -1, room: 300, scale: 1), 150)
        XCTAssertEqual(Split.dragged(wanted: 400, by: -10, room: 300, scale: 1), 164)
    }

    /// "Zero change keeps the wanted height".
    func testAnActionThatShowsNoChangeKeepsTheWantedHeight() {
        XCTAssertEqual(Split.dragged(wanted: 400, by: 0, room: 300, scale: 1), 400)
        XCTAssertEqual(Split.stepped(wanted: 400, steps: 1, room: 300, scale: 1), 400)
        XCTAssertNil(Split.dragged(wanted: nil, by: 0, room: 600, scale: 1))
        XCTAssertEqual(Split.stepped(wanted: 72, steps: -1, room: 600, scale: 1), 72)
    }
}
