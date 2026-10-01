import XCTest
@testable import TarmacKit

/// S9–S11, K6, K14: the open switcher's keys.
final class SwitcherKeysTests: XCTestCase {
    private typealias State = SwitcherKeys.State

    private let shift: UInt = 1 << 17
    private let control: UInt = 1 << 18
    private let option: UInt = 1 << 19
    private let command: UInt = 1 << 20

    /// Display labels: `alpha`, `apex`, `board-2`. `apex` is active.
    private let boards = [
        BoardSwitcher.BoardSummary(boardID: "board-0", name: "alpha", running: 0, bell: 0, cards: 0, isLive: false),
        BoardSwitcher.BoardSummary(boardID: "board-1", name: "apex", running: 0, bell: 0, cards: 0, isLive: false),
        BoardSwitcher.BoardSummary(boardID: "board-2", name: nil, running: 0, bell: 0, cards: 0, isLive: false),
    ]
    private let active = "board-1"

    private func letter(_ c: Character, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: 0, characters: String(c), charactersIgnoringModifiers: String(c), modifierFlags: mods)
    }

    private func named(_ keyCode: UInt16, _ mods: UInt = 0) -> KeyPress {
        KeyPress(keyCode: keyCode, characters: "", charactersIgnoringModifiers: "", modifierFlags: mods)
    }

    private func esc(_ mods: UInt = 0) -> KeyPress { named(53, mods) }
    private func enter(_ mods: UInt = 0) -> KeyPress { named(36, mods) }
    private func backspace(_ mods: UInt = 0) -> KeyPress { named(51, mods) }
    private func up(_ mods: UInt = 0) -> KeyPress { named(126, mods) }
    private func down(_ mods: UInt = 0) -> KeyPress { named(125, mods) }

    private func handle(
        _ press: KeyPress, _ state: State, boardCount: Int? = nil
    ) -> (state: State, effect: SwitcherKeys.Effect) {
        SwitcherKeys.handle(
            press, state: state, summaries: boards, active: active, boardCount: boardCount ?? boards.count
        )
    }

    // MARK: opening (K6)

    func testOpensOnTheActiveRowWithAnEmptyFilter() {
        XCTAssertEqual(SwitcherKeys.opened(summaries: boards, active: "board-1"), State(selected: 1))
        XCTAssertEqual(SwitcherKeys.opened(summaries: boards, active: "board-2"), State(selected: 2))
    }

    func testOpensOnTheFirstRowWhenTheActiveBoardIsNotListed() {
        XCTAssertEqual(SwitcherKeys.opened(summaries: boards, active: "gone"), State())
        XCTAssertEqual(SwitcherKeys.opened(summaries: [], active: "board-0"), State())
    }

    // MARK: ESC (S9, S10, S11)

    func testEscClosesAndResets() {
        let r = handle(esc(), State(filter: "a", selected: 1))
        XCTAssertEqual(r.effect, .close)
        XCTAssertEqual(r.state, State())
    }

    func testEscCancelsARenameAndStaysOpen() {
        let r = handle(esc(), State(filter: "a", selected: 1, editing: true, editBuffer: "new"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(filter: "a", selected: 1))
    }

    func testEscDisarmsADeleteAndStaysOpen() {
        let r = handle(esc(), State(selected: 2, confirmingDelete: true))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(selected: 2))
    }

    func testEscIsEscUnderAnyModifier() {
        XCTAssertEqual(handle(esc(shift), State()).effect, .close)
        XCTAssertEqual(handle(esc(command), State()).effect, .close)
    }

    // MARK: ↑/↓ (S9)

    func testArrowsMoveTheSelectionWithoutWrapping() {
        XCTAssertEqual(handle(down(), State(selected: 0)).state.selected, 1)
        XCTAssertEqual(handle(down(), State(selected: 2)).state.selected, 2)
        XCTAssertEqual(handle(up(), State(selected: 1)).state.selected, 0)
        XCTAssertEqual(handle(up(), State(selected: 0)).state.selected, 0)
        XCTAssertEqual(handle(down(), State()).effect, .none)
    }

    func testArrowsMoveWithinTheFilteredRows() {
        XCTAssertEqual(handle(down(), State(filter: "a", selected: 1)).state.selected, 1, "two rows match")
    }

    func testArrowsDisarmADelete() {
        XCTAssertEqual(handle(down(), State(confirmingDelete: true)).state, State(selected: 1))
        XCTAssertEqual(handle(up(), State(selected: 1, confirmingDelete: true)).state, State(selected: 0))
    }

    func testArrowsAreNotBlockedByARename() {
        let r = handle(down(), State(editing: true, editBuffer: "new"))
        XCTAssertEqual(r.state, State(selected: 1, editing: true, editBuffer: "new"))
    }

    // MARK: Return (S9, S10)

    func testReturnSwitchesToTheSelectedRow() {
        let r = handle(enter(), State(filter: "a", selected: 0))
        XCTAssertEqual(r.effect, .switchTo("board-0"))
        XCTAssertEqual(r.state, State())
    }

    func testReturnOnTheActiveBoardOnlyCloses() {
        let r = handle(enter(), State(selected: 1))
        XCTAssertEqual(r.effect, .close)
        XCTAssertEqual(r.state, State())
    }

    func testReturnWithNoRowStaysOpen() {
        let state = State(filter: "zzz")
        let r = handle(enter(), state)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, state)
    }

    func testReturnCommitsARenameTrimmedAndStaysOpen() {
        let r = handle(enter(), State(filter: "a", selected: 1, editing: true, editBuffer: "  infra  "))
        XCTAssertEqual(r.effect, .rename(boardID: "board-1", name: "infra"))
        XCTAssertEqual(r.state, State(filter: "a", selected: 1))
    }

    func testReturnWithABlankRenameClearsTheName() {
        let r = handle(enter(), State(editing: true, editBuffer: "   "))
        XCTAssertEqual(r.effect, .rename(boardID: "board-0", name: ""))
    }

    func testReturnWithNoRowLeavesRenameModeWithoutRenaming() {
        let r = handle(enter(), State(filter: "zzz", editing: true, editBuffer: "new"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(filter: "zzz"))
    }

    func testReturnAllowsEveryModifierButCommand() {
        XCTAssertEqual(handle(enter(shift), State()).effect, .switchTo("board-0"))
        XCTAssertEqual(handle(enter(option), State()).effect, .switchTo("board-0"))
        XCTAssertEqual(handle(enter(command), State()).effect, .leaveForMenu)
    }

    // MARK: ⌘1–9 (S9)

    func testCommandDigitSwitchesToThatVisibleRow() {
        XCTAssertEqual(handle(letter("1", command), State()).effect, .switchTo("board-0"))
        XCTAssertEqual(handle(letter("3", command), State()).effect, .switchTo("board-2"))
        XCTAssertEqual(handle(letter("1", command), State(filter: "b")).effect, .switchTo("board-2"))
        XCTAssertEqual(handle(letter("1", command), State(filter: "b")).state, State())
    }

    func testCommandDigitOnTheActiveBoardOnlyCloses() {
        XCTAssertEqual(handle(letter("2", command), State()).effect, .close)
    }

    func testCommandDigitPastTheRowsStaysOpen() {
        let state = State(filter: "a", selected: 1)
        let r = handle(letter("3", command), state)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, state)
    }

    func testCommandDigitIsNotBlockedByARename() {
        XCTAssertEqual(handle(letter("1", command), State(editing: true, editBuffer: "x")).effect, .switchTo("board-0"))
    }

    // MARK: typing and ⌫ (S9, S10)

    func testTypingExtendsTheFilterAndSelectsTheFirstRow() {
        let r = handle(letter("a"), State(selected: 2))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(filter: "a", selected: 0))
        XCTAssertEqual(handle(letter("P", shift), State(filter: "a")).state.filter, "aP")
    }

    func testTypingDisarmsADelete() {
        XCTAssertEqual(handle(letter("a"), State(confirmingDelete: true)).state, State(filter: "a"))
    }

    func testTypingWhileRenamingEditsTheBufferOnly() {
        let r = handle(letter("x"), State(filter: "a", selected: 1, editing: true, editBuffer: "ape"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(filter: "a", selected: 1, editing: true, editBuffer: "apex"))
    }

    /// ⌫ clamps the selection into the wider list; it does not reset it.
    func testBackspaceShortensTheFilterAndKeepsTheSelection() {
        let r = handle(backspace(), State(filter: "a", selected: 1))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, State(filter: "", selected: 1))
    }

    func testBackspaceClampsTheSelectionIntoTheNewRows() {
        XCTAssertEqual(handle(backspace(), State(filter: "ap", selected: 1)).state, State(filter: "a", selected: 1))
        XCTAssertEqual(handle(backspace(), State(filter: "apx", selected: 2)).state, State(filter: "ap", selected: 0))
    }

    func testBackspaceOnAnEmptyFilterChangesNothing() {
        XCTAssertEqual(handle(backspace(), State(selected: 2)).state, State(selected: 2))
    }

    func testBackspaceDisarmsADelete() {
        XCTAssertEqual(handle(backspace(), State(filter: "a", confirmingDelete: true)).state, State())
    }

    func testBackspaceWhileRenamingEditsTheBufferOnly() {
        let r = handle(backspace(shift), State(filter: "a", selected: 1, editing: true, editBuffer: "apex"))
        XCTAssertEqual(r.state, State(filter: "a", selected: 1, editing: true, editBuffer: "ape"))
        let empty = State(editing: true)
        XCTAssertEqual(handle(backspace(), empty).state, empty)
    }

    /// ⌥⌫ and ⌃⌫ are not ⌫: swallowed, and an armed delete stays armed.
    func testBackspaceUnderOptionOrControlIsSwallowed() {
        let state = State(filter: "a", confirmingDelete: true)
        for mods in [option, control] {
            let r = handle(backspace(mods), state)
            XCTAssertEqual(r.effect, .none, "\(mods)")
            XCTAssertEqual(r.state, state, "\(mods)")
        }
    }

    // MARK: ⌘N (S9)

    func testCommandNCreatesABoardAndCloses() {
        let r = handle(letter("n", command), State(filter: "a", selected: 1))
        XCTAssertEqual(r.effect, .create)
        XCTAssertEqual(r.state, State())
        XCTAssertEqual(handle(letter("n", command), State(editing: true)).effect, .create, "not blocked by a rename")
    }

    // MARK: ⌘E (S10)

    func testCommandESeedsARenameFromTheSelectedRowsLabel() {
        XCTAssertEqual(handle(letter("e", command), State(selected: 1)).state, State(selected: 1, editing: true, editBuffer: "apex"))
        XCTAssertEqual(
            handle(letter("e", command), State(selected: 2)).state,
            State(selected: 2, editing: true, editBuffer: "board-2"), "an unnamed board is seeded with its slug"
        )
        XCTAssertEqual(handle(letter("e", command), State()).effect, .none)
    }

    func testCommandEDisarmsADelete() {
        let r = handle(letter("e", command), State(confirmingDelete: true))
        XCTAssertEqual(r.state, State(editing: true, editBuffer: "alpha"))
    }

    func testCommandEWithNoRowDoesNothing() {
        let state = State(filter: "zzz")
        let r = handle(letter("e", command), state)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, state)
    }

    // MARK: ⌘⌫ (S11)

    func testCommandBackspaceArmsThenDeletesTheSelectedRow() {
        let armed = handle(backspace(command), State(selected: 2))
        XCTAssertEqual(armed.effect, .none)
        XCTAssertEqual(armed.state, State(selected: 2, confirmingDelete: true))
        let deleted = handle(backspace(command), armed.state)
        XCTAssertEqual(deleted.effect, .delete(boardID: "board-2"))
        XCTAssertEqual(deleted.state, State())
    }

    func testTheLastBoardIsNeverArmed() {
        let state = State()
        let r = handle(backspace(command), state, boardCount: 1)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, state)
    }

    /// The filter narrowing to one row does not make that board the last one.
    func testDeleteCountsEveryBoardNotTheFilteredRows() {
        let r = handle(backspace(command), State(filter: "b"))
        XCTAssertEqual(r.state, State(filter: "b", confirmingDelete: true))
    }

    func testCommandBackspaceWithNoRowDoesNothing() {
        let state = State(filter: "zzz")
        XCTAssertEqual(handle(backspace(command), state).state, state)
    }

    func testCommandBackspaceIsIgnoredWhileRenaming() {
        let state = State(editing: true, editBuffer: "apex")
        let r = handle(backspace(command), state)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state, state)
    }

    // MARK: everything else (K14)

    func testAnUnhandledCommandChordIsLeftForTheMenu() {
        let state = State(filter: "a", selected: 1, confirmingDelete: true)
        for c in ["q", "h", "m", "v", "t"] as [Character] {
            let r = handle(letter(c, command), state)
            XCTAssertEqual(r.effect, .leaveForMenu, "⌘\(c)")
            XCTAssertEqual(r.state, state, "⌘\(c)")
        }
        XCTAssertEqual(handle(letter("e", command | option), state).effect, .leaveForMenu)
    }

    func testAnyOtherKeyIsSwallowed() {
        let state = State(filter: "a", selected: 1, confirmingDelete: true)
        let keys = [named(48), named(48, option), named(123), letter("å", option), letter("a", control)]
        for key in keys {
            let r = handle(key, state)
            XCTAssertEqual(r.effect, .none, "\(key)")
            XCTAssertEqual(r.state, state, "\(key)")
        }
    }

    func testCommandBackspaceArmsUnderAnyOtherModifier() {
        let r = handle(backspace(command | option), State(selected: 2))
        XCTAssertEqual(r.state, State(selected: 2, confirmingDelete: true))
    }

    func testArrowsMoveUnderAnyModifier() {
        XCTAssertEqual(handle(up(command), State(selected: 1)).state.selected, 0)
        XCTAssertEqual(handle(down(shift), State(selected: 0)).state.selected, 1)
    }
}
