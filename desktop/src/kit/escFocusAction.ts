// Port of TarmacKit/EscFocusAction.swift — the pure rule for the card-focus
// branch of the ESC cascade (issue #15). A focused DOC card drops focus on ESC;
// a focused TERMINAL (or nothing focused) is NOT handled here, so ESC passes
// through to the prime terminal's program (agent-interrupt / vim / less). The
// terminal pass-through is enforced by the caller only acting on `"defocus"`.

/** The only handled outcome — drop card focus and swallow the ESC. */
export type EscFocusOutcome = "defocus";

/**
 * `"defocus"` iff a doc card is focused; `null` otherwise (terminal focused or
 * nothing focused) ⇒ ESC is not handled here and passes through.
 */
export function forFocusedDoc(isDoc: boolean): EscFocusOutcome | null {
  return isDoc ? "defocus" : null;
}
