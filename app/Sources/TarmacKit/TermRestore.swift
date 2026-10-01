/// Pure decision for P5 terminal restore: for each persisted terminal tile,
/// whether the app re-binds the card to a daemon-owned live pty (consuming the
/// replayed scrollback that follows the restore) or cold-spawns a fresh shell.
///
/// Kept in TarmacKit so the partition is unit-tested away from AppKit; the app
/// (`AppController.restoreTerminals`) orchestrates the prime/extra-card wiring
/// around these decisions. A tile re-binds iff its persisted `term_id` is among
/// the daemon's reported live terms (`Restore.liveTerms`); everything else cold-
/// spawns — a tile with no persisted id, a shell that exited while detached, or a
/// daemon that restarted (all shells gone ⇒ `liveTerms` empty ⇒ all cold-spawn,
/// the pre-P5 behaviour).
public enum TermRestore {
    public enum Plan: Equatable {
        /// Adopt the daemon's still-live pty under this exact id; do NOT spawn.
        case rebind(termID: String)
        /// Mint a fresh id and spawn a new shell (today's restore behaviour).
        case coldSpawn
    }

    /// One plan per persisted terminal tile, in tile order. `tileTermIDs[i]` is
    /// tile i's persisted `term_id` (nil for a legacy single-terminal tile).
    public static func plan(tileTermIDs: [String?], liveTerms: Set<String>) -> [Plan] {
        tileTermIDs.map { id in
            if let id, liveTerms.contains(id) { return .rebind(termID: id) }
            return .coldSpawn
        }
    }
}
