import { describe, it, expect } from "vitest";
import { xtermHandlesKey, type TermKeyRouteInput } from "./termKeyRoute";

function decide(over: Partial<TermKeyRouteInput>) {
  return xtermHandlesKey({
    type: "keydown",
    key: "",
    composing: false,
    meta: false,
    alt: false,
    ctrl: false,
    kittyFlags: 0,
    ...over,
  });
}

describe("xtermHandlesKey", () => {
  it("leaves plain printable keys to the beforeinput interceptor", () => {
    expect(decide({ key: "a" })).toBe(false);
    expect(decide({ key: " " })).toBe(false);
    expect(decide({ key: "/" })).toBe(false);
  });

  it("handles non-keydown events", () => {
    expect(decide({ type: "keyup", key: "a" })).toBe(true);
    expect(decide({ type: "keypress", key: "a" })).toBe(true);
  });

  it("handles IME composition", () => {
    expect(decide({ key: "a", composing: true })).toBe(true);
  });

  it("handles ⌃ and ⌥ chords", () => {
    expect(decide({ key: "c", ctrl: true })).toBe(true);
    expect(decide({ key: "o", alt: true })).toBe(true);
  });

  it("handles named keys", () => {
    expect(decide({ key: "Enter" })).toBe(true);
    expect(decide({ key: "ArrowUp" })).toBe(true);
    expect(decide({ key: "Enter", meta: true })).toBe(true);
  });

  it("handles plain printable keys when a kitty program asks for every key as an escape code", () => {
    expect(decide({ key: "a", kittyFlags: 8 })).toBe(true);
    expect(decide({ key: "a", kittyFlags: 31 })).toBe(true);
  });

  it("leaves plain printable keys to the beforeinput interceptor under other kitty flags", () => {
    expect(decide({ key: "a", kittyFlags: 5 })).toBe(false);
    expect(decide({ key: "a", kittyFlags: 1 })).toBe(false);
  });

  it("leaves ⌘V to the browser so the Edit menu's Paste fires", () => {
    expect(decide({ key: "v", meta: true })).toBe(false);
    expect(decide({ key: "V", meta: true })).toBe(false);
    expect(decide({ key: "v", meta: true, kittyFlags: 5 })).toBe(false);
  });

  it("handles other ⌘ chords, where a kitty program can bind them", () => {
    expect(decide({ key: "c", meta: true, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "s", meta: true, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "a", meta: true })).toBe(true);
  });

  it("handles ⌘ chords on keyup and during IME composition", () => {
    expect(decide({ type: "keyup", key: "v", meta: true })).toBe(true);
    expect(decide({ key: "v", meta: true, composing: true })).toBe(true);
  });

  it("handles ⌃⌘ and ⌥⌘ chords", () => {
    expect(decide({ key: "v", meta: true, ctrl: true })).toBe(true);
    expect(decide({ key: "v", meta: true, alt: true })).toBe(true);
  });
});
