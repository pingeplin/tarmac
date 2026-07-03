// Issue #50 / spec 2607.0004: ESC must clear a fresh doc card's highlight in
// place, never remove it. S2/S3 pin reference identity on untouched cards —
// the load-bearing anti-mutation check that fails under a naive
// `.map(c => ({...c}))` implementation that always allocates new objects.
import { describe, it, expect } from "vitest";
import { clearFreshDoc } from "./clearFreshDoc";
import type { CardModel } from "../board/model";

const frame = { x: 0, y: 0, w: 100, h: 100 };

const doc = (path: string, fresh: boolean): CardModel => ({
  kind: "doc", path, frame, z: 1, ownerTermId: "t1", repoColor: 2, fresh, attached: true,
});

const term = (termId: string): CardModel => ({
  kind: "term", termId, frame, z: 0,
  label: "", live: true, dead: false, prime: false, bell: false, needsSpawn: false,
});

describe("clearFreshDoc", () => {
  // S1: clears fresh, preserves every other field.
  it("S1: clears fresh on a fresh doc card, keeping its other fields", () => {
    const card = doc("/a.md", true);
    const [result] = clearFreshDoc([card]);
    expect(result).toEqual({ ...card, fresh: false });
  });

  // S2: only the fresh card's object changes; siblings are the SAME reference.
  it("S2: untouched cards are returned by reference, not copied", () => {
    const freshDoc = doc("/a.md", true);
    const staleDoc = doc("/b.md", false);
    const t = term("t1");
    const cards = [freshDoc, staleDoc, t];
    const result = clearFreshDoc(cards);

    expect(result[0]).not.toBe(freshDoc);
    expect(result[0]).toEqual({ ...freshDoc, fresh: false });
    expect(result[1]).toBe(staleDoc);
    expect(result[2]).toBe(t);
  });

  // S3: no fresh card anywhere ⇒ every element is reference-equal to the input.
  it("S3: no-op when nothing is fresh — every card reference-equal to input", () => {
    const cards = [doc("/a.md", false), term("t1")];
    const result = clearFreshDoc(cards);
    expect(result[0]).toBe(cards[0]);
    expect(result[1]).toBe(cards[1]);
  });

  // S4: multiple fresh docs — the function clears all of them, not just one.
  it("S4: clears every fresh doc card when more than one is fresh", () => {
    const a = doc("/a.md", true);
    const b = doc("/b.md", true);
    const result = clearFreshDoc([a, b]);
    expect(result[0].kind === "doc" && result[0].fresh).toBe(false);
    expect(result[1].kind === "doc" && result[1].fresh).toBe(false);
  });

  // S5: empty input doesn't throw.
  it("S5: empty array returns an empty array", () => {
    expect(clearFreshDoc([])).toEqual([]);
  });
});
