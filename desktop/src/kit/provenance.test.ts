import { describe, it, expect } from 'vitest';
import { remappedOwners } from './provenance';

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
