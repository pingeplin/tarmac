// Port of TarmacKit/DocRouting.swift — pure per-board doc→terminal owner
// resolution (M3). A doc card binds to *its* terminal — the term_id that opened
// it — scoped to a single board's owners and that board's set of live terminals.
// Kept as the one unit-tested source of truth; the app maps the returned id to a
// board card (and confirms the card exists).
//
// `owners` is one board's doc-owner mapping (doc path → owner term_id), modelled
// here as a Record<string, string> — `path in owners` / `owners[path]` mirror
// Swift's `owners[path]` dictionary lookup. Passing one board's keys is what
// scopes resolution per board.

export type Owners = Record<string, string>;

/**
 * The term_id that should own a doc card on a board, or undefined (→ the doc
 * stays loose). Returns the recorded owner only when it is one of the board's
 * live terminals; an owner that vanished (absent from `liveTermIds`) or a doc
 * with no recorded owner resolves to undefined.
 *
 * Passing one board's `owners` + `liveTermIds` scopes resolution per board: a
 * doc owned by `t1` on board A does not resolve on board B, whose `liveTermIds`
 * lacks `t1`.
 */
export function resolveOwner(
  path: string,
  owners: Owners,
  liveTermIds: ReadonlySet<string>,
): string | undefined {
  const owner = owners[path];
  if (owner === undefined || !liveTermIds.has(owner)) return undefined;
  return owner;
}

/**
 * The inverse of `resolveOwner` for one terminal: every doc path that records
 * `termId` as its owner. Order is unspecified (mirrors Swift's dictionary
 * iteration); callers that need a single winner rank the result — ⌘P picks the
 * most recent. Liveness is not checked here: the caller (⌘P) inverts the
 * *focused* terminal, which is by definition live.
 */
export function docsOwnedBy(termId: string, owners: Owners): string[] {
  const result: string[] = [];
  for (const path in owners) {
    if (owners[path] === termId) result.push(path);
  }
  return result;
}
