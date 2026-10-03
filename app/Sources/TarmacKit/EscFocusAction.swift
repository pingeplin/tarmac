/// Pure rule for the card-focus branch of the ESC cascade (issue #15): a focused
/// DOC card drops focus on ESC; a focused TERMINAL (or nothing focused) is not
/// handled here, so ESC passes through to the prime terminal's program
/// (agent-interrupt / vim / less). Kept in TarmacKit so the rule is unit-tested;
/// the terminal pass-through is enforced by the caller only acting on `.defocus`.
public enum EscFocusAction {
    /// The only handled outcome — drop card focus and swallow the ESC.
    public enum Outcome: Equatable {
        case defocus
    }

    /// `.defocus` iff a doc card is focused; `nil` otherwise (terminal focused or
    /// nothing focused) ⇒ ESC is not handled here and passes through.
    public static func forFocusedDoc(_ isDoc: Bool) -> Outcome? {
        isDoc ? .defocus : nil
    }
}
