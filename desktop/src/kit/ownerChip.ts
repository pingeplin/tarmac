// The doc-card owner-chip rule (port of AppController.ownerChipLabel/ownerCardID): the
// chip shows "← <owner terminal label>" ONLY for an attached doc whose owner terminal
// still exists with a non-empty label. A detached/loose doc, a missing owner, or an
// empty owner label all yield null (chip hidden). Pure so the parity rule is unit-tested.

/** The owner-chip label (without the "← " prefix), or null when the chip is hidden.
 *  `labelOf` returns the current display label of a term id, or undefined if that
 *  term is gone (exited / not on this board). */
export function ownerChipName(
  attached: boolean,
  ownerTermId: string | undefined,
  labelOf: (termId: string) => string | undefined,
): string | null {
  if (!attached || !ownerTermId) return null;
  const label = labelOf(ownerTermId);
  return label !== undefined && label.length > 0 ? label : null;
}
