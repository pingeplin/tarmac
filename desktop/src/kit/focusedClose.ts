// Port of TarmacKit/FocusedClose.swift — pure routing for ⌘W "close the focused
// card" (issue #15). Kept pure so the rule is unit-tested away from the UI; the
// app only wires the result. The terminal branch reuses `termExit.decide(0, …)`,
// so the "a deliberate close is treated like a clean exit; replace only when it
// was the last terminal" rule lives in one place. Mirrors the `termExit` pattern.

import { decide as termExitDecide } from "./termExit";

/** The kind of card ⌘W is acting on — the focused card, or nothing focused. */
export type Kind = "doc" | "term" | "none";

/**
 * What ⌘W does to the focused card.
 *   - "noop":          nothing focused — no-op (the keystroke is still swallowed
 *                      by the app, so ⌘W never closes the window).
 *   - "shelfDoc":      focused doc — park it on the shelf (recoverable).
 *   - closeTerminal:   focused terminal — terminate it; `replace` ⇒ it was the
 *                      board's last live terminal, so spawn a fresh shell in its
 *                      place (else offer undo).
 */
export type Action =
  | "noop"
  | "shelfDoc"
  | { kind: "closeTerminal"; replace: boolean };

/**
 * `otherLiveTerminals` is the count of OTHER live terminals on the board; it only
 * affects the `"term"` case (decides replace-vs-undo). The terminal branch routes
 * through `termExit.decide(0, …)`: a deliberate close is a clean exit, so replace
 * exactly when that decision is "removeAndReplace" (otherLiveTerminals === 0).
 */
export function decide(kind: Kind, otherLiveTerminals: number): Action {
  switch (kind) {
    case "none":
      return "noop";
    case "doc":
      return "shelfDoc";
    case "term": {
      const replace = termExitDecide(0, otherLiveTerminals) === "removeAndReplace";
      return { kind: "closeTerminal", replace };
    }
  }
}
