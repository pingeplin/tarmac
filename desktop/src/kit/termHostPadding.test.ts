import { describe, it, expect } from "vitest";
import { termHostPadding } from "./termHostPadding";

describe("termHostPadding", () => {
  it("returns the base values at rs=1", () => {
    expect(termHostPadding(1)).toBe("8px 10px 16px");
  });

  it("scales all three values by rs at rs=2", () => {
    expect(termHostPadding(2)).toBe("16px 20px 32px");
  });
});
