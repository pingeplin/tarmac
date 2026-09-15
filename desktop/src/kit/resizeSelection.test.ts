import { describe, it, expect } from "vitest";
import { flushesOnResize } from "./resizeSelection";

describe("flushesOnResize", () => {
  it("flushes a highlighted range in the page", () => {
    expect(flushesOnResize({ type: "Range", focusTag: "BODY" })).toBe(true);
    expect(flushesOnResize({ type: "Range", focusTag: "IFRAME" })).toBe(true);
    expect(flushesOnResize({ type: "Range", focusTag: undefined })).toBe(true);
  });

  it("has no highlight to flush in a caret", () => {
    expect(flushesOnResize({ type: "Caret", focusTag: "BODY" })).toBe(false);
  });

  it("has nothing to flush without a selection", () => {
    expect(flushesOnResize({ type: "None", focusTag: "BODY" })).toBe(false);
  });

  it("leaves a focused terminal's caret alone", () => {
    expect(flushesOnResize({ type: "Caret", focusTag: "TEXTAREA" })).toBe(false);
  });

  it("leaves a range inside a focused textarea alone, like xterm's right-click word", () => {
    expect(flushesOnResize({ type: "Range", focusTag: "TEXTAREA" })).toBe(false);
  });
});
