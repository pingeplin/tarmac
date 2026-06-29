// Port of TarmacKit/TermExit.swift — the pure decision for a terminal card's
// lifecycle when its shell exits, plus the partition of which terminal tiles
// survive into the persisted layout. Kept pure so the rules are unit-tested away
// from the UI; the app only does the wiring. Mirrors the `TermRestore.plan()`
// pattern.
//
// Exit-code semantics (from the daemon's `Exit` message): `null` = killed by a
// signal, `0` = clean exit, non-zero = error.

/**
 * What the app does with the exiting terminal's card.
 *   - "remove":           clean exit while other live terminals remain — remove
 *                         the card and offer an undo.
 *   - "removeAndReplace": clean exit of the board's last live terminal — remove
 *                         the card and spawn a fresh boot terminal in its place,
 *                         so the board always keeps >=1 live terminal.
 *   - "holdOpen":         error (non-zero) or signal (null) exit — keep a
 *                         read-only placeholder so the failure stays visible.
 */
export type Action = "remove" | "removeAndReplace" | "holdOpen";

/**
 * Decide the action for an exit with `code`, given `otherLiveTerminals` — the
 * count of OTHER terminals on the same board still backed by a live pty
 * (excluding the one that just exited).
 *
 * A failure (error or signal) ALWAYS holds open: it wins over the last-terminal
 * guarantee so the user can read what went wrong, rather than the card vanishing
 * and being silently replaced. The guarantee re-applies only when the user later
 * removes the placeholder.
 */
export function decide(code: number | null, otherLiveTerminals: number): Action {
  if (code !== 0) return "holdOpen";
  return otherLiveTerminals === 0 ? "removeAndReplace" : "remove";
}

/**
 * Whether a terminal tile is written to the persisted layout. An `exited` shell
 * (clean-removed, or held-open after an error) is excluded so it never reappears
 * on relaunch. A DETACHED shell (the daemon connection dropped, so its pty may
 * still be alive — `live === false` but NOT exited) is kept, so it re-binds on
 * reconnect. Callers MUST source `exited` from the card's terminal/`dead` state,
 * never from `live`.
 */
export function persistsTile(exited: boolean): boolean {
  return !exited;
}

/** A terminal tile: its id paired with whether its shell has exited. */
export interface TermTile {
  termId: string;
  exited: boolean;
}

/**
 * The persisted-tile partition: given each terminal tile's id paired with
 * whether its shell has exited, returns the ids that survive into the persisted
 * layout, in input order. `persistLayout` routes through this so the
 * exited-vs-live guard is unit-tested here, not re-derived inline.
 */
export function persistedTermIds(tiles: TermTile[]): string[] {
  return tiles.filter((t) => persistsTile(t.exited)).map((t) => t.termId);
}
