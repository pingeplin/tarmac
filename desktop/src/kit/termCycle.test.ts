import { describe, it, expect } from "vitest";
import { cycleOrder, step, cycleFrom, type CycleTerm } from "./termCycle";

describe("TermCycle", () => {
  // --- cycleOrder ---

  describe("cycleOrder", () => {
    it("drops dead terms, preserves spawn order", () => {
      const terms: CycleTerm[] = [
        { termId: "a", isLive: true },
        { termId: "b", isLive: false },
        { termId: "c", isLive: true },
      ];
      expect(cycleOrder(terms)).toEqual(["a", "c"]);
    });

    it("returns all ids when all are live", () => {
      const terms: CycleTerm[] = [
        { termId: "x", isLive: true },
        { termId: "y", isLive: true },
      ];
      expect(cycleOrder(terms)).toEqual(["x", "y"]);
    });

    it("returns [] when all terms are dead", () => {
      const terms: CycleTerm[] = [
        { termId: "a", isLive: false },
        { termId: "b", isLive: false },
      ];
      expect(cycleOrder(terms)).toEqual([]);
    });

    it("returns [] for empty input", () => {
      expect(cycleOrder([])).toEqual([]);
    });
  });

  // --- step ---

  describe("step", () => {
    it("returns undefined for next when order is empty", () => {
      expect(step([], "a", "next")).toBeUndefined();
    });

    it("returns undefined for prev when order is empty", () => {
      expect(step([], "a", "prev")).toBeUndefined();
    });

    it("returns the single id for next when there is 1 live term", () => {
      expect(step(["a"], "a", "next")).toBe("a");
    });

    it("returns the single id for prev when there is 1 live term", () => {
      expect(step(["a"], "a", "prev")).toBe("a");
    });

    it("returns first id when currentTermId is undefined and dir is next", () => {
      expect(step(["a", "b", "c"], undefined, "next")).toBe("a");
    });

    it("returns last id when currentTermId is undefined and dir is prev", () => {
      expect(step(["a", "b", "c"], undefined, "prev")).toBe("c");
    });

    it("returns first id when currentTermId is not in order and dir is next", () => {
      expect(step(["a", "b", "c"], "z", "next")).toBe("a");
    });

    it("returns last id when currentTermId is not in order and dir is prev", () => {
      expect(step(["a", "b", "c"], "z", "prev")).toBe("c");
    });

    it("wraps from last to first on next", () => {
      expect(step(["a", "b", "c"], "c", "next")).toBe("a");
    });

    it("wraps from first to last on prev", () => {
      expect(step(["a", "b", "c"], "a", "prev")).toBe("c");
    });

    it("steps forward from mid-list on next", () => {
      expect(step(["a", "b", "c"], "a", "next")).toBe("b");
    });

    it("steps backward from mid-list on prev", () => {
      expect(step(["a", "b", "c"], "c", "prev")).toBe("b");
    });
  });

  // --- cycleFrom ---

  describe("cycleFrom", () => {
    it("end-to-end: skips dead term, cycles to next live", () => {
      const terms: CycleTerm[] = [
        { termId: "a", isLive: true },
        { termId: "b", isLive: false },
        { termId: "c", isLive: true },
      ];
      // order = ["a", "c"]; current = "a" → next = "c"
      expect(cycleFrom(terms, "a", "next")).toBe("c");
    });

    it("end-to-end: wraps from last live to first live", () => {
      const terms: CycleTerm[] = [
        { termId: "a", isLive: true },
        { termId: "b", isLive: false },
        { termId: "c", isLive: true },
      ];
      // order = ["a", "c"]; current = "c" → next wraps = "a"
      expect(cycleFrom(terms, "c", "next")).toBe("a");
    });

    it("end-to-end: returns undefined when no live terms", () => {
      const terms: CycleTerm[] = [
        { termId: "a", isLive: false },
        { termId: "b", isLive: false },
      ];
      expect(cycleFrom(terms, "a", "next")).toBeUndefined();
    });
  });
});
