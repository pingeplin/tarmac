import { describe, it, expect } from "vitest";
import { forFocusedDoc } from "./escFocusAction";

// Port of EscFocusActionTests.swift (2606.0004): the card-focus branch of the
// ESC cascade (issue #15) — a focused doc defocuses; a focused terminal (or
// nothing) passes through to the program.
describe("EscFocusAction", () => {
  it("focused doc defocuses", () => {
    expect(forFocusedDoc(true)).toBe("defocus");
  });

  // Anti-regression: a non-doc focus (a focused terminal, or nothing focused)
  // must NOT defocus, so ESC keeps reaching the terminal program
  // (agent-interrupt / vim). It must return null, never "defocus".
  it("non-doc passes through", () => {
    expect(forFocusedDoc(false)).toBeNull();
  });
});
