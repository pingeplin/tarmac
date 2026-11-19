/// The inbox panel's keyboard while it is open (spec 2611.0013). ⌘K, ⌘I and
/// ⌘W never get here (`KeyLadder` takes them first).
///
/// The selection is an item id, not an index: the list changes while the
/// panel is open, and a report that lands just before ↵ must not move what ↵
/// acts on.
public enum InboxKeys {
    /// Where ↑↓ go (spec 2611.0018 D6). It is state, not first responder:
    /// the panel keeps the keys while the grip has the focus.
    public enum Focus: Equatable, Sendable {
        case list, grip
    }

    public struct State: Equatable, Sendable {
        public var filter: Inbox.Filter
        public var selected: Inbox.ItemID?
        public var focus: Focus

        public init(filter: Inbox.Filter = .all, selected: Inbox.ItemID? = nil, focus: Focus = .list) {
            self.filter = filter
            self.selected = selected
            self.focus = focus
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
        /// The grip's ↑ (+1) or ↓ (−1): the preview pane grows or shrinks
        /// by `InboxPreviewSplit.step`.
        case resizePane(steps: Int)
    }

    /// `rows` is what the panel shows, in order. Tab and ⇧Tab change the
    /// filter and clear the selection: `reselect` then picks the new top row.
    public static func handle(_ press: KeyPress, state: State, rows: [Inbox.ItemID]) -> (state: State, effect: Effect) {
        var next = state
        // A ⌘ chord the panel has no use for is the menu's, ⌘↑ and ⌘Esc too.
        guard !press.command else { return (state, .leaveForMenu) }
        switch press.named {
        case .escape:
            return (state, .close)
        case .enter:
            return (state, state.selected.map(Effect.jump) ?? .none)
        case .backspace:
            return (state, state.selected.map(Effect.remove) ?? .none)
        case .arrowUp, .arrowDown:
            if state.focus == .grip { return (state, .resizePane(steps: press.named == .arrowUp ? 1 : -1)) }
            let step = press.named == .arrowUp ? -1 : 1
            guard let index = state.selected.flatMap(rows.firstIndex(of:)) else {
                next.selected = rows.first
                return (next, .none)
            }
            next.selected = rows[max(0, min(rows.count - 1, index + step))]
            return (next, .none)
        case .tab:
            next.filter = press.shift ? state.filter.previous : state.filter.next
            next.selected = nil
            next.focus = .list
            return (next, .none)
        default:
            return (state, .none)
        }
    }

    /// A click on a row (spec 2611.0018 D5): it selects and previews. A
    /// second click flies only when it lands on the selected row: the list
    /// scrolls the row the first click selected into view, so the second
    /// click of a double-click can land on a neighbour.
    public static func click(_ id: Inbox.ItemID, count: Int, state: State) -> (state: State, effect: Effect) {
        if count >= 2, id == state.selected { return (state, .jump(id)) }
        var next = state
        next.selected = id
        next.focus = .list
        return (next, .none)
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
