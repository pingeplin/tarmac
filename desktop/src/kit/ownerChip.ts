// The doc-card owner-chip rule (port of AppController.ownerChipLabel/ownerCardID): the
// chip shows "← <owner terminal label>" whenever the owner terminal still exists with a
// non-empty label. A missing owner or an empty owner label yields null (chip hidden).
// Provenance chrome is independent of the `attached` gravity flag. Pure so the rule is
// unit-tested.

/** The owner-chip label (without the "← " prefix), or null when the chip is hidden.
 *  `labelOf` returns the current display label of a term id, or undefined if that
 *  term is gone (exited / not on this board). */
export function ownerChipName(
  ownerTermId: string | undefined,
  labelOf: (termId: string) => string | undefined,
): string | null {
  if (!ownerTermId) return null;
  const label = labelOf(ownerTermId);
  return label !== undefined && label.length > 0 ? label : null;
}
