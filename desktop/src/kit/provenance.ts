// Port of TarmacKit/Provenance.swift — the pure doc→terminal provenance logic
// (Phase 5b). Kept view-independent so the best-effort cross-restart re-anchoring
// heuristic is a single, unit-tested source of truth; the app coordinator calls
// into it. Swift exposed a `Provenance` enum of static funcs; here it is a plain
// exported function.

/**
 * Whether a doc card should be dimmed. Owner-linked docs are never dimmed;
 * owner-less docs were never dimmed either. Always returns false — provenance
 * (dim) is independent of the `attached` gravity flag.
 */
export function docDimmed(_ownerTermId: string | null | undefined): boolean {
  return false;
}

/**
 * Whether the provenance edge from the owner terminal to this doc should be
 * shown. True only when the doc has an owner terminal and that terminal's card
 * is present on the board. Never gated on `attached`.
 */
export function provenanceEdgeShown(
  ownerTermId: string | null | undefined,
  ownerCardPresent: boolean,
): boolean {
  return ownerTermId != null && ownerCardPresent;
}

/**
 * Re-anchors persisted doc→terminal owners across a restart (decision 2,
 * best-effort). `owners` maps doc path → its persisted owner `term_id` (from the
 * prior run). `oldToNew` maps each restored terminal's persisted id to its
 * freshly-minted id this run.
 *
 * - An owner present in `oldToNew` is rewritten to the reborn terminal.
 * - When exactly one terminal restored (`soleTerminal` non-null), any owner that
 *   did not remap is re-anchored to it — the common single-terminal restart stays
 *   lossless (every doc re-binds to the one terminal).
 * - Otherwise (multi-terminal) an owner whose terminal genuinely vanished is left
 *   unchanged; the caller resolves it to no card, so the doc restores loose. Full
 *   per-terminal identity across restart is M3.
 */
export function remappedOwners(
  owners: Map<string, string>,
  oldToNew: Map<string, string>,
  soleTerminal: string | null,
): Map<string, string> {
  const result = new Map(owners);
  for (const [path, oldOwner] of owners) {
    const newOwner = oldToNew.get(oldOwner);
    if (newOwner !== undefined) {
      result.set(path, newOwner);
    } else if (soleTerminal !== null) {
      result.set(path, soleTerminal);
    }
  }
  return result;
}
