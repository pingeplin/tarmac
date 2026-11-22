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
        /// Focused doc — close its card.
        case closeDoc
        /// Focused terminal — terminate it; `replace` ⇒ it was the board's last
        /// live terminal, so spawn a fresh shell in its place. The daemon is
        /// always told, live or dead: for a dead card it deletes the record
        /// (2611.0011, D12).
        case closeTerminal(replace: Bool)
    }

    /// `otherLiveTerminals` is the count of OTHER live terminals on the board; it
    /// only affects the `.term` case (decides whether to replace it).
    public static func decide(kind: Kind, otherLiveTerminals: Int) -> Action {
        switch kind {
        case .none:
            return .noop
        case .doc:
            return .closeDoc
        case .term:
            return .closeTerminal(
                replace: TermExit.decide(code: 0, otherLiveTerminals: otherLiveTerminals) == .removeAndReplace)
        }
    }
}
