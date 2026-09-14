import { describe, it, expect } from "vitest";
import { route, type TermKeyRouteInput } from "./termKeyRoute";

function decide(over: Partial<TermKeyRouteInput>) {
  return route({
    type: "keydown",
    key: "",
    composing: false,
    meta: false,
    alt: false,
    ctrl: false,
    kittyActive: false,
    ...over,
  });
}

describe("termKeyRoute", () => {
  it("sends plain printable keys through beforeinput", () => {
    expect(decide({ key: "a" })).toBe("beforeinput");
    expect(decide({ key: " " })).toBe("beforeinput");
    expect(decide({ key: "/" })).toBe("beforeinput");
  });

  it("leaves non-keydown events to xterm", () => {
    expect(decide({ type: "keyup", key: "a" })).toBe("xterm");
    expect(decide({ type: "keypress", key: "a" })).toBe("xterm");
  });

  it("leaves IME composition to xterm", () => {
    expect(decide({ key: "a", composing: true })).toBe("xterm");
  });

  it("leaves ⌃ and ⌥ chords to xterm", () => {
    expect(decide({ key: "c", ctrl: true })).toBe("xterm");
    expect(decide({ key: "o", alt: true })).toBe("xterm");
  });

  it("leaves named keys to xterm", () => {
    expect(decide({ key: "Enter" })).toBe("xterm");
    expect(decide({ key: "ArrowUp" })).toBe("xterm");
    expect(decide({ key: "Enter", meta: true })).toBe("xterm");
  });

  it("leaves plain printable keys to xterm while a kitty keyboard program is active", () => {
    expect(decide({ key: "a", kittyActive: true })).toBe("xterm");
  });

  it("hands ⌘V to the browser so the Edit menu's Paste fires", () => {
    expect(decide({ key: "v", meta: true })).toBe("browser");
    expect(decide({ key: "V", meta: true })).toBe("browser");
    expect(decide({ key: "v", meta: true, kittyActive: true })).toBe("browser");
  });

  it("leaves other ⌘ chords to xterm, where a kitty program can bind them", () => {
    expect(decide({ key: "c", meta: true, kittyActive: true })).toBe("xterm");
    expect(decide({ key: "s", meta: true, kittyActive: true })).toBe("xterm");
    expect(decide({ key: "a", meta: true })).toBe("xterm");
  });

  it("leaves ⌘ chords to xterm on keyup and during IME composition", () => {
    expect(decide({ type: "keyup", key: "v", meta: true })).toBe("xterm");
    expect(decide({ key: "v", meta: true, composing: true })).toBe("xterm");
  });

  it("leaves ⌃⌘ and ⌥⌘ chords to xterm", () => {
    expect(decide({ key: "v", meta: true, ctrl: true })).toBe("xterm");
    expect(decide({ key: "v", meta: true, alt: true })).toBe("xterm");
  });
});
