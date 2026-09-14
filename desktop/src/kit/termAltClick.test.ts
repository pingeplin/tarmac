import { describe, it, expect } from "vitest";
import { altClickMovesCursor } from "./termAltClick";

describe("altClickMovesCursor", () => {
  it("moves the prompt cursor on ⌥-click when the program does not track the mouse", () => {
    expect(altClickMovesCursor("none")).toBe(true);
  });

  it("sends no cursor keys on ⌥-click while the program tracks the mouse", () => {
    expect(altClickMovesCursor("x10")).toBe(false);
    expect(altClickMovesCursor("vt200")).toBe(false);
    expect(altClickMovesCursor("drag")).toBe(false);
    expect(altClickMovesCursor("any")).toBe(false);
  });
});
