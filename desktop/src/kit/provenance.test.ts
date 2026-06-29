import { describe, it, expect } from 'vitest';
import { remappedOwners, docDimmed, provenanceEdgeShown } from './provenance';

// Phase 5b: the best-effort doc→terminal provenance re-anchoring across a restart
// (decision 2). Terminal ptys are gone on restart, so persisted owner ids never
// match the freshly-minted ones directly — `remappedOwners` bridges them, with a
// single-terminal heuristic that keeps the common case lossless.
describe('remappedOwners', () => {
  // An owner whose terminal restored is rewritten to the reborn id.
  it('remaps owner to the reborn terminal', () => {
    const owners = new Map([['/a.md', 'old1'], ['/b.md', 'old2']]);
    const oldToNew = new Map([['old1', 'new1'], ['old2', 'new2']]);
    const out = remappedOwners(owners, oldToNew, null);
    expect(out).toEqual(new Map([['/a.md', 'new1'], ['/b.md', 'new2']]));
  });

  // Single-terminal restart (the common case): every owner-bearing doc re-anchors
  // to the one terminal, even a doc owned by an even-earlier id.
  it('single terminal re-anchors all docs losslessly', () => {
    const owners = new Map([['/a.md', 'old1'], ['/b.md', 'ancient'], ['/c.md', 'old1']]);
    const oldToNew = new Map([['old1', 'boot']]);
    const out = remappedOwners(owners, oldToNew, 'boot');
    expect(out).toEqual(new Map([['/a.md', 'boot'], ['/b.md', 'boot'], ['/c.md', 'boot']]));
  });

  // Multi-terminal: a doc whose owning terminal genuinely vanished keeps its stale
  // id (the caller then restores it loose), while a doc whose owner restored is
  // remapped.
  it('multi-terminal leaves an orphaned owner stale', () => {
    const owners = new Map([['/a.md', 'old1'], ['/orphan.md', 'gone']]);
    const oldToNew = new Map([['old1', 'new1'], ['old2', 'new2']]);
    const out = remappedOwners(owners, oldToNew, null);
    expect(out.get('/a.md')).toBe('new1');
    // an orphaned owner is left stale (resolves to no card)
    expect(out.get('/orphan.md')).toBe('gone');
  });

  // No owners ⇒ nothing to remap.
  it('empty owners stays empty', () => {
    const out = remappedOwners(new Map(), new Map([['old1', 'new1']]), 'new1');
    expect(out.size).toBe(0);
  });
});

// S1, S2, S4, S5: provenance predicates are independent of the `attached` flag.
describe('docDimmed', () => {
  // S1: an owner-linked doc that has been dragged (attached=false in the app
  // layer) must not be dimmed. docDimmed ignores attached entirely.
  it('S1: owner-linked doc is never dimmed, regardless of whether it was dragged', () => {
    // This test would fail if the old `c.ownerTermId != null && !c.attached`
    // logic were still in play — a dragged card with an owner would return true.
    expect(docDimmed('term-1')).toBe(false);
  });

  // S4: an owner-less doc is also never dimmed.
  it('S4: owner-less doc (null) is never dimmed', () => {
    expect(docDimmed(null)).toBe(false);
  });

  it('S4 (undefined): owner-less doc (undefined) is never dimmed', () => {
    expect(docDimmed(undefined)).toBe(false);
  });
});

describe('provenanceEdgeShown', () => {
  // S2: edge is shown for an owner-linked doc whose owner card is present,
  // regardless of `attached`. This fails if the old `attached === true` gate
  // were reintroduced (a dragged card would hide the edge).
  it('S2: owner-linked doc with owner present → edge shown (attached-independent)', () => {
    expect(provenanceEdgeShown('term-1', true)).toBe(true);
  });

  // S4: no edge for an owner-less doc.
  it('S4: owner-less doc (null) with no owner present → no edge', () => {
    expect(provenanceEdgeShown(null, false)).toBe(false);
  });

  it('S4 (null + true): owner-less doc yields no edge even if ownerCardPresent were somehow true', () => {
    expect(provenanceEdgeShown(null, true)).toBe(false);
  });

  // S5: no dangling edge when the owner terminal has been closed.
  it('S5: owner-linked doc whose owner card is absent → no edge', () => {
    expect(provenanceEdgeShown('term-1', false)).toBe(false);
  });
});
