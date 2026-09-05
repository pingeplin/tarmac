// Pure decision for issue #77: which terminal (if any) a freshly-spawned ⌘T
// terminal should inherit its cwd from. The daemon resolves the actual LIVE
// directory at spawn time (term.rs::live_cwd) — this only decides WHICH
// terminal to ask, so the wiring in App.tsx stays a thin pass-through.

/** A terminal card, reduced to what a prime-terminal decision needs. */
export interface CwdInheritCandidate {
  termId: string;
  prime: boolean;
  live: boolean;
  dead: boolean;
}

/** The board's live prime terminal — the one keyboard focus goes home to — or
 *  undefined when there is none (empty board, or a prime that isn't live). */
export function primeTermId(cards: CwdInheritCandidate[]): string | undefined {
  return cards.find((c) => c.prime && c.live && !c.dead)?.termId;
}

/**
 * The term_id whose live cwd a new ⌘T terminal should inherit, or undefined
 * when there is no eligible source. ⌘T then falls back to the daemon's default cwd.
 */
export function inheritCwdSource(cards: CwdInheritCandidate[]): string | undefined {
  return primeTermId(cards);
}
