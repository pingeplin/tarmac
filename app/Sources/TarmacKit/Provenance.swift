/// Pure doc→terminal provenance logic (Phase 5b). Kept view-independent in
/// TarmacKit so the best-effort cross-restart re-anchoring heuristic is a single
/// unit-tested source of truth; `AppController` calls into it.
public enum Provenance {
    /// Whether the provenance edge from the owner terminal to this doc should be
    /// shown. True only when the doc has an owner terminal and that terminal's
    /// card is present on the board. Never gated on `attached` — that is the
    /// gravity flag (does the card snap back beside its terminal), so dragging a
    /// doc away must not hide the edge.
    public static func edgeShown(ownerTermID: String?, ownerCardPresent: Bool) -> Bool {
        ownerTermID != nil && ownerCardPresent
    }

    /// Re-anchors persisted doc→terminal owners across a restart (decision 2,
    /// best-effort). `owners` maps doc path → its persisted owner `term_id` (from
    /// the prior run). `oldToNew` maps each restored terminal's persisted id to
    /// its freshly-minted id this run.
    ///
    /// - An owner present in `oldToNew` is rewritten to the reborn terminal.
    /// - When exactly one terminal restored (`soleTerminal` non-nil), any owner
    ///   that did not remap is re-anchored to it — the common single-terminal
    ///   restart stays lossless (every doc re-binds to the one terminal).
    /// - Otherwise (multi-terminal) an owner whose terminal genuinely vanished is
    ///   left unchanged; the caller resolves it to no card, so the doc restores
    ///   loose. Full per-terminal identity across restart is M3.
    public static func remappedOwners(
        _ owners: [String: String],
        oldToNew: [String: String],
        soleTerminal: String?
    ) -> [String: String] {
        var result = owners
        for (path, oldOwner) in owners {
            if let newOwner = oldToNew[oldOwner] {
                result[path] = newOwner
            } else if let only = soleTerminal {
                result[path] = only
            }
        }
        return result
    }
}
