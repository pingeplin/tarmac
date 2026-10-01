/// Pure routing for ⌘W "close the focused card" (issue #15). Kept in TarmacKit so
/// the rule is unit-tested away from AppKit; `AppController` only wires the result.
/// The terminal branch reuses `TermExit.decide(code: 0, …)`, so the "a deliberate
/// close is treated like a clean exit; replace only when it was the last terminal"
/// rule lives in one place. Mirrors the `TermExit` pattern.
public enum FocusedClose {
    /// The kind of card ⌘W is acting on — the focused card, or nothing focused.
    public enum Kind: Equatable {
        case doc
        case term
        case none
    }

    /// What ⌘W does to the focused card.
    public enum Action: Equatable {
        /// Nothing focused — no-op (the keystroke is still swallowed by the app,
        /// so ⌘W never closes the window).
        case noop
        /// Focused doc — park it on the shelf (recoverable).
        case shelfDoc
        /// Focused terminal — terminate it; `replace` ⇒ it was the board's last
        /// live terminal, so spawn a fresh shell in its place (else offer undo).
        /// `signalClose` ⇒ the pty was still live, so the daemon needs telling.
        case closeTerminal(replace: Bool, signalClose: Bool)
    }

    /// `otherLiveTerminals` is the count of OTHER live terminals on the board; it
    /// only affects the `.term` case (decides replace-vs-undo).
    ///
    /// `dead` (`.term` only): the focused terminal's pty has already exited. Then
    /// `signalClose` is false — there is nothing live to close, so the caller must
    /// not depend on `TermClose` being a safe no-op for an already-gone `term_id`.
    /// `replace` is unaffected by `dead`.
    public static func decide(kind: Kind, otherLiveTerminals: Int, dead: Bool = false) -> Action {
        switch kind {
        case .none:
            return .noop
        case .doc:
            return .shelfDoc
        case .term:
            let replace = TermExit.decide(code: 0, otherLiveTerminals: otherLiveTerminals) == .removeAndReplace
            return .closeTerminal(replace: replace, signalClose: !dead)
        }
    }
}
