import XCTest
@testable import TarmacKit

/// Spec 2611.0018 D5, D6: a click selects, a double-click on the selected row
/// flies, and the grip takes ↑↓ while it has the focus.
final class InboxPointerTests: XCTestCase {
    private typealias State = InboxKeys.State

    private func id(_ term: String) -> Inbox.ItemID { Inbox.ItemID(termID: term, family: .report) }
    private var a: Inbox.ItemID { id("a") }
    private var b: Inbox.ItemID { id("b") }
    private var x: Inbox.ItemID { id("x") }

    private func handle(_ press: KeyPress, _ state: State, _ rows: [Inbox.ItemID]) -> (State, InboxKeys.Effect) {
        let result = InboxKeys.handle(press, state: state, rows: rows)
        return (result.state, result.effect)
    }

    private func click(_ id: Inbox.ItemID, _ count: Int, _ state: State) -> (State, InboxKeys.Effect) {
        let result = InboxKeys.click(id, count: count, state: state)
        return (result.state, result.effect)
    }

    func testS7AClickSelectsAndTakesTheFocusBackFromTheGrip() {
        let (state, effect) = click(b, 1, State(filter: .reports, selected: a, focus: .grip))
        XCTAssertEqual(state, State(filter: .reports, selected: b, focus: .list))
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    func testS7ASingleClickOnTheSelectedRowDoesNotFly() {
        let state = State(filter: .all, selected: b)
        let (after, effect) = click(b, 1, state)
        XCTAssertEqual(effect, InboxKeys.Effect.none)
        XCTAssertEqual(after, state)
    }

    func testS8ADoubleClickOnTheSelectedRowFlies() {
        let state = State(filter: .all, selected: b)
        let (after, effect) = click(b, 2, state)
        XCTAssertEqual(effect, .jump(b))
        XCTAssertEqual(after, state)
    }

    func testS28ADoubleClickOnAnotherRowOnlySelects() {
        let (state, effect) = click(b, 2, State(filter: .all, selected: a, focus: .grip))
        XCTAssertEqual(state, State(filter: .all, selected: b, focus: .list))
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    func testS26ADoubleClickOnAStaleSelectedIdLeavesTheJumpToCheckIt() {
        let state = State(filter: .all, selected: x)
        let (after, effect) = click(x, 2, state)
        XCTAssertEqual(effect, .jump(x))
        XCTAssertEqual(after, state)
    }

    func testS9TheGripsArrowsResizeAndLeaveTheSelection() {
        let state = State(filter: .all, selected: a, focus: .grip)
        let up = handle(named(126), state, [a, b])
        XCTAssertEqual(up.1, .resizePane(steps: 1))
        XCTAssertEqual(up.0, state)
        let down = handle(named(125), state, [a, b])
        XCTAssertEqual(down.1, .resizePane(steps: -1))
        XCTAssertEqual(down.0, state)
    }

    func testS10TheGripKeepsEveryOtherKey() {
        let state = State(filter: .all, selected: a, focus: .grip)
        XCTAssertEqual(handle(named(36), state, [a, b]).1, .jump(a))
        XCTAssertEqual(handle(named(53), state, [a, b]).1, .close)
        let (tabbed, _) = handle(named(48), state, [a, b])
        XCTAssertEqual(tabbed, State(filter: .reports, selected: nil, focus: .list))
    }

    func testS25AFilterChangeTakesTheFocusBackFromTheGrip() {
        let (state, _) = handle(named(48, shift), State(filter: .all, selected: a, focus: .grip), [a])
        XCTAssertEqual(state.focus, .list)
        XCTAssertEqual(state.filter, .exit)
    }

    func testTheListIsTheFocusOfANewState() {
        XCTAssertEqual(State().focus, .list)
    }
}
