// Issue #50: ESC's "dismiss fresh doc" rung must only clear the highlight, never
// remove the card — removal stays reserved for the ✕ / Cmd+W path (removeDoc /
// focusedClose). Kept pure (mirrors focusedClose.ts/termExit.ts) so the rule is
// unit-tested away from the untested App.tsx UI shell.

import type { CardModel } from "../board/model";

/**
 * Clears `fresh` on every doc card that has it set. Cards that don't change
 * (non-fresh docs, all term cards) are returned by the SAME reference, matching
 * the unchanged-reference convention `onCardMoveEnd` already uses — so this is
 * safe to call unconditionally from `setActiveCards` without extra churn.
 */
export function clearFreshDoc(cards: CardModel[]): CardModel[] {
  return cards.map((c) => (c.kind === "doc" && c.fresh ? { ...c, fresh: false } : c));
}
