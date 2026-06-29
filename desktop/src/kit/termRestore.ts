// Port of TarmacKit/TermRestore.swift — the P5 decision for terminal restore:
// for each persisted terminal tile, whether the app re-binds the card to a
// daemon-owned live pty (consuming the replayed scrollback that follows the
// restore) or cold-spawns a fresh shell.
//
// A tile re-binds iff its persisted `term_id` is among the daemon's reported
// live terms; everything else cold-spawns — a tile with no persisted id (null),
// a shell that exited while detached, or a daemon that restarted (all shells
// gone ⇒ liveTerms empty ⇒ all cold-spawn, the pre-P5 behaviour).

/** Adopt the daemon's still-live pty under this exact id; do NOT spawn. */
export interface RebindPlan {
  kind: "rebind";
  termId: string;
}

/** Mint a fresh id and spawn a new shell (today's restore behaviour). */
export interface ColdSpawnPlan {
  kind: "coldSpawn";
}

export type Plan = RebindPlan | ColdSpawnPlan;

/**
 * One plan per persisted terminal tile, in tile order. `tileTermIds[i]` is
 * tile i's persisted `term_id` (null for a legacy single-terminal tile). A tile
 * re-binds iff its id is non-null and present in `liveTerms`; otherwise it
 * cold-spawns. Input order is preserved.
 */
export function plan(tileTermIds: (string | null)[], liveTerms: Set<string>): Plan[] {
  return tileTermIds.map((id) =>
    id !== null && liveTerms.has(id)
      ? { kind: "rebind", termId: id }
      : { kind: "coldSpawn" },
  );
}
