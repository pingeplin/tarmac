import { describe, it, expect } from "vitest";
import { ownerChipName } from "./ownerChip";

describe("OwnerChip", () => {
  const makeLabels = (entries: [string, string][]) => {
    const map = new Map<string, string>(entries);
    return (id: string) => map.get(id);
  };

  it("owner present + non-empty label → returns that label", () => {
    const labelOf = makeLabels([["term-1", "claude"]]);
    expect(ownerChipName("term-1", labelOf)).toBe("claude");
  });

  // S6: a dragged (loose, attached=false) doc whose owner term exists with a
  // non-empty label still shows the chip. This test would fail if the old
  // `if (!attached) return null` gate were reintroduced.
  it("S6: loose (dragged) doc with owner term present + non-empty label → returns label", () => {
    const labelOf = makeLabels([["term-1", "claude"]]);
    // `attached` is no longer a parameter — chip shows based only on ownerTermId + label
    expect(ownerChipName("term-1", labelOf)).toBe("claude");
  });

  it("ownerTermId === undefined → null", () => {
    const labelOf = makeLabels([]);
    expect(ownerChipName(undefined, labelOf)).toBeNull();
  });

  it("owner present but labelOf returns undefined (owner term gone) → null", () => {
    const labelOf = makeLabels([]); // term-1 not in map → undefined
    expect(ownerChipName("term-1", labelOf)).toBeNull();
  });

  it("owner present but labelOf returns empty label → null", () => {
    const labelOf = makeLabels([["term-1", ""]]);
    expect(ownerChipName("term-1", labelOf)).toBeNull();
  });
});
