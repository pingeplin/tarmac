import { describe, it, expect } from "vitest";
import { inheritCwdSource, type CwdInheritCandidate } from "./cwdInherit";

const term = (over: Partial<CwdInheritCandidate>): CwdInheritCandidate => ({
  termId: "t1",
  prime: false,
  live: true,
  dead: false,
  ...over,
});

describe("inheritCwdSource", () => {
  it("returns undefined for an empty board", () => {
    expect(inheritCwdSource([])).toBeUndefined();
  });

  it("returns the live prime terminal's id", () => {
    const cards = [term({ termId: "t1" }), term({ termId: "t2", prime: true })];
    expect(inheritCwdSource(cards)).toBe("t2");
  });

  it("falls back to undefined when the prime terminal is dead", () => {
    const cards = [term({ termId: "t1", prime: true, live: false, dead: true })];
    expect(inheritCwdSource(cards)).toBeUndefined();
  });

  it("falls back to undefined when the prime terminal is not live", () => {
    const cards = [term({ termId: "t1", prime: true, live: false })];
    expect(inheritCwdSource(cards)).toBeUndefined();
  });

  it("falls back to undefined when no card is prime", () => {
    const cards = [term({ termId: "t1" }), term({ termId: "t2" })];
    expect(inheritCwdSource(cards)).toBeUndefined();
  });
});
