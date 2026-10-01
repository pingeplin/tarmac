/// The ⌘K switcher's keyboard while it is open: every key it is handed changes
/// its state, asks the app for something, or both. ⌘K and ⌘W never get here
/// (`KeyLadder` takes them first).
///
/// Rename mode does not block navigation: ↑/↓, ⌘1–9 and ⌘N act as they do
/// outside it, as in the web app.
public enum SwitcherKeys {
    public struct State: Equatable, Sendable {
        /// The typed prefix filter.
        public var filter: String
        /// The highlighted row among the visible ones.
        public var selected: Int
        /// Rename mode: typing edits `editBuffer` instead of the filter.
        public var editing: Bool
        public var editBuffer: String
        /// A first ⌘⌫ armed the delete of the selected row.
        public var confirmingDelete: Bool

        public init(
            filter: String = "", selected: Int = 0, editing: Bool = false, editBuffer: String = "",
            confirmingDelete: Bool = false
        ) {
            self.filter = filter
            self.selected = selected
            self.editing = editing
            self.editBuffer = editBuffer
            self.confirmingDelete = confirmingDelete
        }
    }

    public enum Effect: Equatable, Sendable {
        /// The switcher took the key; at most its state changed.
        case none
        case close
        /// Close and switch to another board.
        case switchTo(String)
        /// Ask the daemon for a new board and close.
        case create
        /// Rename the board; the switcher stays open.
        case rename(boardID: String, name: String)
        /// Delete the board and close.
        case delete(boardID: String)
        /// No handler and ⌘ is held: the menu decides what the chord is. The
        /// key still must not reach the terminal behind the switcher.
        case leaveForMenu
    }

    /// The state the switcher opens in: no filter, the active board's row
    /// selected.
    public static func opened(summaries: [BoardSwitcher.BoardSummary], active: String) -> State {
        let rows = BoardSwitcher.rows(summaries: summaries, active: active, filter: "")
        return State(selected: rows.firstIndex(where: \.isActive) ?? 0)
    }

    /// `boardCount` is every board there is, whatever the filter shows.
    public static func handle(
        _ press: KeyPress, state: State, summaries: [BoardSwitcher.BoardSummary], active: String, boardCount: Int
    ) -> (state: State, effect: Effect) {
        func rows(_ filter: String) -> [BoardSwitcher.BoardRow] {
            BoardSwitcher.rows(summaries: summaries, active: active, filter: filter)
        }
        let visible = rows(state.filter)
        let row = visible.indices.contains(state.selected) ? visible[state.selected] : nil
        var next = state

        if press.named == .escape {
            if state.editing {
                next.editing = false
                next.editBuffer = ""
                return (next, .none)
            }
            if state.confirmingDelete {
                next.confirmingDelete = false
                return (next, .none)
            }
            return (State(), .close)
        }

        if press.isCommandChord("e") {
            guard let row else { return (state, .none) }
            next.editing = true
            next.editBuffer = row.display
            next.confirmingDelete = false
            return (next, .none)
        }

        if press.command, press.named == .backspace {
            guard !state.editing, let row, BoardSwitcher.canDelete(boardCount: boardCount) else {
                return (state, .none)
            }
            if state.confirmingDelete { return (State(), .delete(boardID: row.boardID)) }
            next.confirmingDelete = true
            return (next, .none)
        }

        if press.named == .enter, !press.command {
            if state.editing {
                next.editing = false
                next.editBuffer = ""
                guard let row else { return (next, .none) }
                return (next, .rename(boardID: row.boardID, name: BoardSwitcher.sanitizedName(state.editBuffer)))
            }
            guard let row else { return (state, .none) }
            return open(row.boardID, active: active)
        }

        if press.named == .arrowUp || press.named == .arrowDown {
            // Disarmed so a second ⌘⌫ cannot land on another row than the one
            // the user armed.
            next.confirmingDelete = false
            let step = press.named == .arrowUp ? -1 : 1
            next.selected = BoardSwitcher.clampSelection(state.selected + step, count: visible.count)
            return (next, .none)
        }

        if press.named == .backspace, !press.option, !press.control {
            next.confirmingDelete = false
            if state.editing {
                next.editBuffer = String(state.editBuffer.dropLast())
            } else {
                next.filter = String(state.filter.dropLast())
                next.selected = BoardSwitcher.clampSelection(state.selected, count: rows(next.filter).count)
            }
            return (next, .none)
        }

        if let ordinal = press.commandDigit {
            guard let boardID = BoardSwitcher.boardID(forOrdinal: ordinal, in: visible) else { return (state, .none) }
            return open(boardID, active: active)
        }

        if press.isCommandChord("n") { return (State(), .create) }

        if let typed = press.typed {
            next.confirmingDelete = false
            if state.editing {
                next.editBuffer += typed
            } else {
                next.filter += typed
                next.selected = 0
            }
            return (next, .none)
        }

        return (state, BoardSwitcher.cancelsUnhandledKey(commandHeld: press.command) ? .none : .leaveForMenu)
    }

    /// Choosing the board that is already active only closes the switcher.
    private static func open(_ boardID: String, active: String) -> (state: State, effect: Effect) {
        (State(), boardID == active ? .close : .switchTo(boardID))
    }
}
