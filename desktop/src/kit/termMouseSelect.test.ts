import { describe, it, expect } from "vitest";
import { mouseSelectOptions, swallowsHover } from "./termMouseSelect";

describe("mouseSelectOptions", () => {
  it("keeps xterm's shell behaviour when the program does not track the mouse", () => {
    expect(mouseSelectOptions("none")).toEqual({
      macOptionClickForcesSelection: false,
      altClickMovesCursor: true,
    });
  });

  it("forces ⌥-drag selection and sends no cursor keys while the program tracks the mouse", () => {
    for (const mode of ["x10", "vt200", "drag", "any"] as const) {
      expect(mouseSelectOptions(mode)).toEqual({
        macOptionClickForcesSelection: true,
        altClickMovesCursor: false,
      });
    }
  });
});

describe("swallowsHover", () => {
  it("swallows a buttonless move over a selection while the program tracks the mouse", () => {
    expect(swallowsHover({ mode: "any", buttons: 0, hasSelection: true })).toBe(true);
    expect(swallowsHover({ mode: "vt200", buttons: 0, hasSelection: true })).toBe(true);
  });

  it("lets moves through without a selection, while dragging, or when nothing tracks the mouse", () => {
    expect(swallowsHover({ mode: "any", buttons: 0, hasSelection: false })).toBe(false);
    expect(swallowsHover({ mode: "any", buttons: 1, hasSelection: true })).toBe(false);
    expect(swallowsHover({ mode: "none", buttons: 0, hasSelection: true })).toBe(false);
  });
});
