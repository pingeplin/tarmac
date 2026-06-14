/// Pure board-list navigation (M3): the order-based lookups the boards switcher
/// and the throwaway cycle key share — next-in-display-order (wrapping) and the
/// ⌘1..9 ordinal map. Display order is the `[BoardMeta]` array order. Kept in
/// TarmacKit so the index arithmetic is unit-tested; `AppController` and (P4)
/// the ⌘K switcher call in.
public enum BoardRegistry {
    /// The board id after `current` in display order, wrapping last → first.
    /// nil when there are fewer than two boards (nothing to switch to). An
    /// unknown `current` falls back to the first board.
    public static func nextBoardID(after current: String, in metas: [BoardMeta]) -> String? {
        guard metas.count > 1 else { return nil }
        let idx = metas.firstIndex { $0.boardID == current } ?? -1
        return metas[(idx + 1) % metas.count].boardID
    }

    /// The board id for a 1-based ⌘N ordinal (⌘1 → the first board), or nil when
    /// out of range. (P4 ⌘1..9 jump.)
    public static func boardID(forOrdinal n: Int, in metas: [BoardMeta]) -> String? {
        guard n >= 1, n <= metas.count else { return nil }
        return metas[n - 1].boardID
    }
}
