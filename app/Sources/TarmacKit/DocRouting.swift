/// Pure per-board doc→terminal owner resolution (M3). A doc card binds to *its*
/// terminal — the `term_id` that opened it — scoped to a single board's owners
/// and the set of that board's live terminals. Kept in TarmacKit so the
/// resolution rule is one unit-tested source of truth; `AppController` maps the
/// returned id to a board card (and confirms the card exists).
public enum DocRouting {
    /// The `term_id` that should own a doc card on a board, or nil (→ the doc
    /// stays loose). Returns the recorded owner only when it is one of the
    /// board's live terminals; an owner that vanished (absent from
    /// `liveTermIDs`) or a doc with no recorded owner resolves to nil.
    ///
    /// `owners` is one board's `docOwner` map (doc path → owner `term_id`);
    /// `liveTermIDs` is that same board's live terminal ids — passing one
    /// board's keys is what scopes resolution per board (a doc owned by `t1` on
    /// board A does not resolve on board B, whose `liveTermIDs` lacks `t1`).
    public static func resolveOwner(
        path: String,
        owners: [String: String],
        liveTermIDs: Set<String>
    ) -> String? {
        guard let owner = owners[path], liveTermIDs.contains(owner) else { return nil }
        return owner
    }
}
