// Cross-type z-order contract (S9–S10, spec 2606.0012).
import { describe, it, expect } from "vitest";
import { topZ } from "../board/model";
import type { CardModel } from "../board/model";

const frame = { x: 0, y: 0, w: 100, h: 100 };

const term = (z: number): CardModel => ({
  kind: "term", termId: "t1", frame, z,
  label: "", live: true, dead: false, prime: false, bell: false, needsSpawn: false,
});

const doc = (z: number): CardModel => ({
  kind: "doc", path: "/a.md", frame, z, fresh: false, attached: true,
});

describe("topZ cross-type (S9–S10)", () => {
  it("S9: topZ folds all kinds — global max, not kind-filtered", () => {
    const cards: CardModel[] = [term(15), doc(10), term(3)];
    expect(topZ(cards)).toBe(15);
  });

  it("S10: grab raises above all types — topZ+1 strictly > every z across both kinds", () => {
    const cards: CardModel[] = [term(5), doc(10)];
    const next = topZ(cards) + 1;
    expect(next).toBe(11);
    for (const c of cards) expect(next).toBeGreaterThan(c.z);
  });
});
