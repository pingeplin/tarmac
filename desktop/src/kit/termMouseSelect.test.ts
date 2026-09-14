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
  it("swallows a buttonless move while a selection is shown under any-event tracking", () => {
    expect(swallowsHover({ mode: "any", buttons: 0, hasSelection: true })).toBe(true);
  });

  it("lets moves through under tracking modes that send no hover reports", () => {
    for (const mode of ["none", "x10", "vt200", "drag"] as const) {
      expect(swallowsHover({ mode, buttons: 0, hasSelection: true })).toBe(false);
    }
  });

  it("lets moves through without a selection or while a button is held", () => {
    expect(swallowsHover({ mode: "any", buttons: 0, hasSelection: false })).toBe(false);
    expect(swallowsHover({ mode: "any", buttons: 1, hasSelection: true })).toBe(false);
    expect(swallowsHover({ mode: "any", buttons: 2, hasSelection: true })).toBe(false);
  });
});
