import XCTest
@testable import TarmacKit

/// Spec 2611.0013 S8, S38: the open inbox panel's keys.
final class InboxKeysTests: XCTestCase {
    private typealias State = InboxKeys.State

    private let shift: UInt = 1 << 17
    private let command: UInt = 1 << 20

    private func id(_ term: String) -> Inbox.ItemID { Inbox.ItemID(termID: term, family: .report) }
    private var a: Inbox.ItemID { id("a") }
    private var b: Inbox.ItemID { id("b") }
    private var c: Inbox.ItemID { id("c") }
    private var n: Inbox.ItemID { id("n") }

    private func key(_ keyCode: UInt16, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: keyCode, characters: "", charactersIgnoringModifiers: "", modifierFlags: mods)
    }

    private func letter(_ c: Character, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: 0, characters: String(c), charactersIgnoringModifiers: String(c), modifierFlags: mods)
    }

    private var up: KeyPress { key(126) }
    private var down: KeyPress { key(125) }
    private var enter: KeyPress { key(36) }
    private var backspace: KeyPress { key(51) }
    private var esc: KeyPress { key(53) }
    private var tab: KeyPress { key(48) }
    private var shiftTab: KeyPress { key(48, shift) }

    private func handle(_ press: KeyPress, _ state: State, _ rows: [Inbox.ItemID]) -> (State, InboxKeys.Effect) {
        let result = InboxKeys.handle(press, state: state, rows: rows)
        return (result.state, result.effect)
    }

    func testS8TheArrowsMoveAndStopAtTheEnds() {
        var state = State(filter: .all, selected: a)
        for _ in 0..<3 { (state, _) = handle(down, state, [a, b, c]) }
        XCTAssertEqual(state.selected, c)
        let (atTop, effect) = handle(up, State(filter: .all, selected: a), [a, b, c])
        XCTAssertEqual(atTop.selected, a)
        XCTAssertEqual(effect, InboxKeys.Effect.none)
    }

    func testS8ReturnJumpsBackspaceRemovesAndEscapeCloses() {
        let state = State(filter: .all, selected: b)
        XCTAssertEqual(handle(enter, state, [a, b, c]).1, .jump(b))
        XCTAssertEqual(handle(backspace, state, [a, b, c]).1, .remove(b))
        XCTAssertEqual(handle(esc, state, [a, b, c]).1, .close)
    }

    func testS8TabCyclesTheFiltersAndClearsTheSelectionForTheTopRow() {
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

    func testS8AnyOtherKeyIsTakenAndACommandChordIsLeftForTheMenu() {
        let state = State(filter: .all, selected: a)
        let typed = handle(letter("x"), state, [a])
        XCTAssertEqual(typed.1, InboxKeys.Effect.none)
        XCTAssertEqual(typed.0, state)
        XCTAssertEqual(handle(letter("v", command), state, [a]).1, .leaveForMenu)
        for press in [key(126, command), key(125, command), key(53, command)] {
            XCTAssertEqual(handle(press, state, [a, b]).1, .leaveForMenu, "\(press.keyCode)")
            XCTAssertEqual(handle(press, state, [a, b]).0, state)
        }
    }

    func testS8WithNoRowsReturnAndBackspaceDoNothing() {
        let state = State(filter: .bell, selected: nil)
        XCTAssertEqual(handle(enter, state, []).1, InboxKeys.Effect.none)
        XCTAssertEqual(handle(backspace, state, []).1, InboxKeys.Effect.none)
    }

    func testS38ANewItemAtTheTopDoesNotMoveTheSelection() {
        let selected = InboxKeys.reselect(b, oldRows: [a, b, c], newRows: [n, a, b, c])
        XCTAssertEqual(selected, b)
        XCTAssertEqual(handle(enter, State(filter: .all, selected: selected), [n, a, b, c]).1, .jump(b))
    }

    func testS38AnItemThatLeftHandsTheSelectionToItsOldIndexClamped() {
        XCTAssertEqual(InboxKeys.reselect(b, oldRows: [a, b, c], newRows: [a, c]), c)
        XCTAssertEqual(InboxKeys.reselect(c, oldRows: [a, b, c], newRows: [a, b]), b)
        XCTAssertNil(InboxKeys.reselect(a, oldRows: [a], newRows: []))
    }

    func testS38NoSelectionTakesTheTopRow() {
        XCTAssertEqual(InboxKeys.reselect(nil, oldRows: [], newRows: [a]), a)
        XCTAssertNil(InboxKeys.reselect(nil, oldRows: [], newRows: []))
    }
}
