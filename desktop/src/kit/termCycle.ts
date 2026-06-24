// Cycle-the-prime-terminal logic, ported from AppController.cycleTerminals() in
// the Swift app. Order + selection live here; time-based HUD reveal/fade and
// keyboard wiring stay in the view layer (App.tsx). Never call Date.now() here.
//
// This is the FIRST unit coverage of this logic — the Swift equivalent was inline
// with no dedicated module.

/** One terminal eligible for the cycle: stable id + whether its pty is live. */
export interface CycleTerm {
  termId: string;
  isLive: boolean;
}

export type Direction = "next" | "prev";

/** The ordered cycle: live terminals in stable input (spawn) order; dead ones dropped. */
export function cycleOrder(terms: CycleTerm[]): string[] {
  return terms.filter((t) => t.isLive).map((t) => t.termId);
}

/**
 * The term to focus when cycling `dir` from `currentTermId` over `order`. Wraps.
 * Empty order → undefined. When `currentTermId` is undefined or NOT in `order`
 * (focus was on a doc, or the current term just died): "next" → first, "prev" → last.
 */
export function step(
  order: string[],
  currentTermId: string | undefined,
  dir: Direction,
): string | undefined {
  if (order.length === 0) return undefined;
  const n = order.length;
  const idx = order.indexOf(currentTermId ?? "");
  if (idx < 0) {
    return dir === "next" ? order[0] : order[n - 1];
  }
  const next = (idx + 1) % n;
  const prev = (idx - 1 + n) % n;
  return order[dir === "next" ? next : prev];
}

/** Convenience: step(cycleOrder(terms), currentTermId, dir). */
export function cycleFrom(
  terms: CycleTerm[],
  currentTermId: string | undefined,
  dir: Direction,
): string | undefined {
  return step(cycleOrder(terms), currentTermId, dir);
}
