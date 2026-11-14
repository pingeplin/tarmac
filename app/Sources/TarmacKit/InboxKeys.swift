/// The inbox panel's keyboard while it is open (spec 2611.0013). ⌘K, ⌘I and
/// ⌘W never get here (`KeyLadder` takes them first).
///
/// The selection is an item id, not an index: the list changes while the
/// panel is open, and a report that lands just before ↵ must not move what ↵
/// acts on.
public enum InboxKeys {
    public struct State: Equatable, Sendable {
        public var filter: Inbox.Filter
        public var selected: Inbox.ItemID?

        public init(filter: Inbox.Filter = .all, selected: Inbox.ItemID? = nil) {
            self.filter = filter
            self.selected = selected
        }
    }

    public enum Effect: Equatable, Sendable {
        /// The panel took the key; at most its state changed.
        case none
        case close
        case jump(Inbox.ItemID)
        case remove(Inbox.ItemID)
        /// A ⌘ chord the panel has no use for: the menu decides what it is.
        /// It still must not reach the terminal behind the panel.
        case leaveForMenu
    }

    /// `rows` is what the panel shows, in order. Tab and ⇧Tab change the
    /// filter and clear the selection: `reselect` then picks the new top row.
    public static func handle(_ press: KeyPress, state: State, rows: [Inbox.ItemID]) -> (state: State, effect: Effect) {
        var next = state
        switch press.named {
        case .escape:
            return (state, .close)
        case .enter where !press.command:
            return (state, state.selected.map(Effect.jump) ?? .none)
        case .backspace where !press.command:
            return (state, state.selected.map(Effect.remove) ?? .none)
        case .arrowUp, .arrowDown:
            let step = press.named == .arrowUp ? -1 : 1
            guard let index = state.selected.flatMap(rows.firstIndex(of:)) else {
                next.selected = rows.first
                return (next, .none)
            }
            next.selected = rows[max(0, min(rows.count - 1, index + step))]
            return (next, .none)
        case .tab where !press.command:
            next.filter = press.shift ? state.filter.previous : state.filter.next
            next.selected = nil
            return (next, .none)
        default:
            return (state, press.command ? .leaveForMenu : .none)
        }
    }

    /// The selection after the rows changed: the selected item wherever it
    /// went; else the item now at its old index, clamped; else the top row.
    public static func reselect(_ selected: Inbox.ItemID?, oldRows: [Inbox.ItemID], newRows: [Inbox.ItemID]) -> Inbox.ItemID? {
        guard !newRows.isEmpty else { return nil }
        guard let selected else { return newRows.first }
        if newRows.contains(selected) { return selected }
        let old = oldRows.firstIndex(of: selected) ?? 0
        return newRows[min(old, newRows.count - 1)]
    }
}
