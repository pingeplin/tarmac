/// Pure decision for a terminal card's lifecycle when its shell exits. Kept in
/// TarmacKit so the rule is unit-tested away from AppKit; the app
/// (`AppController.handleExit`) only does the wiring. Mirrors the
/// `TermRestore.plan()` pattern.
///
/// Exit-code semantics (from the daemon's `Exit` message, see `term.rs`): `nil`
/// = killed by a signal, `0` = clean exit, non-zero = error.
public enum TermExit {
    /// What the app does with the exiting terminal's card.
    public enum Action: Equatable {
        /// Clean exit while other live terminals remain — remove the card and
        /// offer an undo.
        case remove
        /// Clean exit of the board's last live terminal — remove the card and
        /// spawn a fresh boot terminal in its place, so the board always keeps
        /// ≥1 live terminal.
        case removeAndReplace
        /// Error (non-zero) or signal (nil) exit — keep a read-only placeholder
        /// so the failure stays visible.
        case holdOpen
    }

    /// Decide the action for an exit with `code`, given `otherLiveTerminals` —
    /// the count of OTHER terminals on the same board still backed by a live pty
    /// (excluding the one that just exited).
    ///
    /// A failure (error or signal) ALWAYS holds open: it wins over the last-
    /// terminal guarantee so the user can read what went wrong, rather than the
    /// card vanishing and being silently replaced. The guarantee re-applies only
    /// when the user later removes the placeholder.
    public static func decide(code: Int?, otherLiveTerminals: Int) -> Action {
        guard code == 0 else { return .holdOpen }
        return otherLiveTerminals == 0 ? .removeAndReplace : .remove
    }
}
