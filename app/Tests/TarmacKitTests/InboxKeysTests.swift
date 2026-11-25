import XCTest

@testable import TarmacKit

/// Spec 2611.0013 "Panel keys move select jump and remove", "Selection follows its item not its index": the open inbox panel's keys.
final class InboxKeysTests: XCTestCase {
    private typealias State = InboxKeys.State

    private func id(_ term: String) -> Inbox.ItemID { Inbox.ItemID(termID: term, family: .report) }
    private var a: Inbox.ItemID { id("a") }
    private var b: Inbox.ItemID { id("b") }
    private var c: Inbox.ItemID { id("c") }
    private var n: Inbox.ItemID { id("n") }

    private var up: KeyPress { named(126) }
    private var down: KeyPress { named(125) }
    private var enter: KeyPress { named(36) }
    private var backspace: KeyPress { named(51) }
    private var esc: KeyPress { named(53) }
    private var tab: KeyPress { named(48) }
    private var shiftTab: KeyPress { named(48, shift) }

    private func handle(_ press: KeyPress, _ state: State, _ rows: [Inbox.ItemID]) -> (State, InboxKeys.Effect) {
        let result = InboxKeys.handle(press, state: state, rows: rows)
        return (result.state, result.effect)
    }

    /// "Panel keys move select jump and remove".
    func testTheArrowsMoveAndStopAtTheEnds() {
        var state = State(filter: .all, selected: a)
        for _ in 0..<3 { (state, _) = handle(down, state, [a, b, c]) }
        XCTAssertEqual(state.selected, c)
        let (atTop, effect) = handle(up, State(filter: .all, selected: a), [a, b, c])
        XCTAssertEqual(atTop.selected, a)
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    /// "Panel keys move select jump and remove".
    func testReturnJumpsBackspaceRemovesAndEscapeCloses() {
        let state = State(filter: .all, selected: b)
        XCTAssertEqual(handle(enter, state, [a, b, c]).1, .jump(b))
        XCTAssertEqual(handle(backspace, state, [a, b, c]).1, .remove(b))
        XCTAssertEqual(handle(esc, state, [a, b, c]).1, .close)
    }

    /// "Panel keys move select jump and remove".
    func testTabCyclesTheFiltersAndClearsTheSelectionForTheTopRow() {
        var state = State(filter: .all, selected: b)
        var seen: [Inbox.Filter] = []
        for _ in 0..<4 {
            (state, _) = handle(tab, state, [a, b, c])
            seen.append(state.filter)
            XCTAssertNil(state.selected)
        }
        XCTAssertEqual(seen, [.reports, .bell, .exit, .all])
        XCTAssertEqual(handle(shiftTab, State(filter: .all, selected: a), [a]).0.filter, .exit)
        XCTAssertEqual(InboxKeys.reselect(nil, oldRows: [a, b, c], newRows: [c, a]), c)
    }

    /// "Panel keys move select jump and remove".
    func testAnyOtherKeyIsTakenAndACommandChordIsLeftForTheMenu() {
        let state = State(filter: .all, selected: a)
        let typed = handle(letter("x"), state, [a])
        XCTAssertEqual(typed.1, InboxKeys.Effect.none)
        XCTAssertEqual(typed.0, state)
        XCTAssertEqual(handle(letter("v", command), state, [a]).1, .leaveForMenu)
        for press in [named(126, command), named(125, command), named(53, command)] {
            XCTAssertEqual(handle(press, state, [a, b]).1, .leaveForMenu, "\(press.keyCode)")
            XCTAssertEqual(handle(press, state, [a, b]).0, state)
        }
    }

    /// "Panel keys move select jump and remove".
    func testWithNoRowsReturnAndBackspaceDoNothing() {
        let state = State(filter: .bell, selected: nil)
        XCTAssertEqual(handle(enter, state, []).1, InboxKeys.Effect.none)
        XCTAssertEqual(handle(backspace, state, []).1, InboxKeys.Effect.none)
    }

    /// "Selection follows its item not its index".
    func testANewItemAtTheTopDoesNotMoveTheSelection() {
        let selected = InboxKeys.reselect(b, oldRows: [a, b, c], newRows: [n, a, b, c])
        XCTAssertEqual(selected, b)
        XCTAssertEqual(handle(enter, State(filter: .all, selected: selected), [n, a, b, c]).1, .jump(b))
    }

    /// "Selection follows its item not its index".
    func testAnItemThatLeftHandsTheSelectionToItsOldIndexClamped() {
        XCTAssertEqual(InboxKeys.reselect(b, oldRows: [a, b, c], newRows: [a, c]), c)
        XCTAssertEqual(InboxKeys.reselect(c, oldRows: [a, b, c], newRows: [a, b]), b)
        XCTAssertNil(InboxKeys.reselect(a, oldRows: [a], newRows: []))
    }

    /// "Selection follows its item not its index".
    func testNoSelectionTakesTheTopRow() {
        XCTAssertEqual(InboxKeys.reselect(nil, oldRows: [], newRows: [a]), a)
        XCTAssertNil(InboxKeys.reselect(nil, oldRows: [], newRows: []))
    }
}

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

    /// "Single click selects a row without flying".
    func testAClickSelectsAndTakesTheFocusBackFromTheGrip() {
        let (state, effect) = click(b, 1, State(filter: .reports, selected: a, focus: .grip))
        XCTAssertEqual(state, State(filter: .reports, selected: b, focus: .list))
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    /// "Single click selects a row without flying".
    func testASingleClickOnTheSelectedRowDoesNotFly() {
        let state = State(filter: .all, selected: b)
        let (after, effect) = click(b, 1, state)
        XCTAssertEqual(effect, InboxKeys.Effect.none)
        XCTAssertEqual(after, state)
    }

    /// "Double-click flies to the selected row".
    func testADoubleClickOnTheSelectedRowFlies() {
        let state = State(filter: .all, selected: b)
        let (after, effect) = click(b, 2, state)
        XCTAssertEqual(effect, .jump(b))
        XCTAssertEqual(after, state)
    }

    /// "Double-click on another row selects it only".
    func testADoubleClickOnAnotherRowOnlySelects() {
        let (state, effect) = click(b, 2, State(filter: .all, selected: a, focus: .grip))
        XCTAssertEqual(state, State(filter: .all, selected: b, focus: .list))
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    /// "Double-click on a stale row id still jumps".
    func testADoubleClickOnAStaleSelectedIdLeavesTheJumpToCheckIt() {
        let state = State(filter: .all, selected: x)
        let (after, effect) = click(x, 2, state)
        XCTAssertEqual(effect, .jump(x))
        XCTAssertEqual(after, state)
    }

    /// "Grip arrow keys resize the pane".
    func testTheGripsArrowsResizeAndLeaveTheSelection() {
        let state = State(filter: .all, selected: a, focus: .grip)
        let up = handle(named(126), state, [a, b])
        XCTAssertEqual(up.1, .resizePane(steps: 1))
        XCTAssertEqual(up.0, state)
        let down = handle(named(125), state, [a, b])
        XCTAssertEqual(down.1, .resizePane(steps: -1))
        XCTAssertEqual(down.0, state)
    }

    /// "Grip keeps Enter Esc and Tab behavior".
    func testTheGripKeepsEveryOtherKey() {
        let state = State(filter: .all, selected: a, focus: .grip)
        XCTAssertEqual(handle(named(36), state, [a, b]).1, .jump(a))
        XCTAssertEqual(handle(named(53), state, [a, b]).1, .close)
        let (tabbed, _) = handle(named(48), state, [a, b])
        XCTAssertEqual(tabbed, State(filter: .reports, selected: nil, focus: .list))
    }

    /// "Shift-Tab from the grip returns to the list".
    func testAFilterChangeTakesTheFocusBackFromTheGrip() {
        let (state, _) = handle(named(48, shift), State(filter: .all, selected: a, focus: .grip), [a])
        XCTAssertEqual(state.focus, .list)
        XCTAssertEqual(state.filter, .exit)
    }

    func testTheListIsTheFocusOfANewState() {
        XCTAssertEqual(State().focus, .list)
    }
}
