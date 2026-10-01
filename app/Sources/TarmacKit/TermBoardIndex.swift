/// The `term_id → board_id` ownership index (M3). Every terminal belongs to
/// exactly one board, so the frames the daemon keys by the globally-unique
/// `term_id` (`output` / `exit` / `term_proc` / `bell`) route to the owning
/// board even when it is backgrounded, and `tarmac open` provenance + board
/// teardown scope per board. Kept pure in TarmacKit so the routing invariants
/// are a single unit-tested source of truth; `AppController` holds one instance
/// and assigns at spawn / removes at exit.
public struct TermBoardIndex {
    private var owner: [String: String] = [:]

    public init() {}

    /// Records that `termID` belongs to `boardID` (set at spawn). Re-assigning a
    /// term that already exists overwrites its owner — documenting the invariant
    /// that no two boards share a `term_id` (last assignment wins).
    public mutating func assign(termID: String, to boardID: String) {
        owner[termID] = boardID
    }

    /// Drops a single terminal (on its exit).
    public mutating func remove(termID: String) {
        owner.removeValue(forKey: termID)
    }

    /// Drops every terminal owned by `boardID` (board teardown / delete).
    public mutating func removeBoard(_ boardID: String) {
        owner = owner.filter { $0.value != boardID }
    }

    /// The board that owns `termID`, or nil when unknown (never assigned, or
    /// already removed at exit).
    public func board(of termID: String) -> String? {
        owner[termID]
    }

    /// Every terminal owned by `boardID`, in no particular order.
    public func terms(of boardID: String) -> [String] {
        owner.compactMap { $0.value == boardID ? $0.key : nil }
    }
}
