import { describe, it, expect } from "vitest";
import { isComposingKey } from "./imeGuard";

describe("isComposingKey", () => {
  it("returns true when isComposing is true", () => {
    expect(isComposingKey({ isComposing: true })).toBe(true);
  });

  it("returns true when keyCode is 229 (legacy IME sentinel)", () => {
    expect(isComposingKey({ keyCode: 229 })).toBe(true);
  });

  it("returns false when neither condition holds", () => {
    expect(isComposingKey({ isComposing: false, keyCode: 13 })).toBe(false);
    expect(isComposingKey({})).toBe(false);
  });
});
