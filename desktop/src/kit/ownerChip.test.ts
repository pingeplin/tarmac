import { describe, it, expect } from "vitest";
import { ownerChipName } from "./ownerChip";

describe("OwnerChip", () => {
  const makeLabels = (entries: [string, string][]) => {
    const map = new Map<string, string>(entries);
    return (id: string) => map.get(id);
  };

  it("attached + owner present + non-empty label → returns that label", () => {
    const labelOf = makeLabels([["term-1", "claude"]]);
    expect(ownerChipName(true, "term-1", labelOf)).toBe("claude");
  });

  it("detached (attached=false) + owner present + label → null", () => {
    const labelOf = makeLabels([["term-1", "claude"]]);
    expect(ownerChipName(false, "term-1", labelOf)).toBeNull();
  });

  it("attached + ownerTermId === undefined → null", () => {
    const labelOf = makeLabels([]);
    expect(ownerChipName(true, undefined, labelOf)).toBeNull();
  });

  it("attached + owner present but labelOf returns undefined (owner term gone) → null", () => {
    const labelOf = makeLabels([]); // term-1 not in map → undefined
    expect(ownerChipName(true, "term-1", labelOf)).toBeNull();
  });

  it("attached + owner present but labelOf returns empty label → null", () => {
    const labelOf = makeLabels([["term-1", ""]]);
    expect(ownerChipName(true, "term-1", labelOf)).toBeNull();
  });
});
