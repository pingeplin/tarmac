import { describe, it, expect } from "vitest";
import { decide, persistsTile, persistedTermIds, type Action, type TermTile } from "./termExit";

// Port of TermExitTests.swift (2606.0001): the exit→action decision and the
// persisted-tile partition.
describe("TermExit", () => {
  // S10: the full decision grid. `code ∈ {0, 1, 130, null}` × `otherLive ∈
  // {0, 2}`. `130` (128 + SIGINT) guards "any non-zero → holdOpen" against a
  // mutation that special-cases high/negative codes. The `(_, 0)` failure cells
  // must be "holdOpen", NOT "removeAndReplace" — failure wins over the
  // last-terminal guarantee (S8b).
  it("decide grid", () => {
    const cases: { code: number | null; otherLive: number; expected: Action }[] = [
      { code: 0, otherLive: 2, expected: "remove" },
      { code: 0, otherLive: 0, expected: "removeAndReplace" },
      { code: 1, otherLive: 2, expected: "holdOpen" },
      { code: 1, otherLive: 0, expected: "holdOpen" },
      { code: 130, otherLive: 2, expected: "holdOpen" },
      { code: 130, otherLive: 0, expected: "holdOpen" },
      { code: null, otherLive: 2, expected: "holdOpen" },
      { code: null, otherLive: 0, expected: "holdOpen" },
    ];
    for (const c of cases) {
      expect(
        decide(c.code, c.otherLive),
        `decide(code: ${c.code === null ? "null" : String(c.code)}, otherLiveTerminals: ${c.otherLive})`,
      ).toBe(c.expected);
    }
  });

  // S3-vs-S1 boundary, pinned on its own so the mutation is unmissable: a clean
  // exit flips "remove" → "removeAndReplace" exactly when it was the last live
  // terminal.
  it("clean exit replaces only at zero on the last terminal", () => {
    expect(decide(0, 1)).toBe("remove");
    expect(decide(0, 0)).toBe("removeAndReplace");
  });

  it("persistsTile excludes exited", () => {
    expect(persistsTile(false)).toBe(true);
    expect(persistsTile(true)).toBe(false);
  });

  // S6 / S9: the partition keeps live AND detached survivors (both
  // `exited === false`) and drops only exited tiles, preserving order. The
  // "detached" entry stands in for a reconnect survivor whose `live === false` —
  // keying the partition off liveness instead of `exited` would wrongly drop it.
  it("persistedTermIds keeps survivors, drops exited", () => {
    const tiles: TermTile[] = [
      { termId: "live", exited: false },
      { termId: "detached", exited: false }, // reconnect survivor: live === false, but NOT exited
      { termId: "exited", exited: true }, // clean-removed-or-held-open: dropped
    ];
    expect(persistedTermIds(tiles)).toEqual(["live", "detached"]);
  });

  it("persistedTermIds empty", () => {
    expect(persistedTermIds([])).toEqual([]);
  });
});
