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
    hasSelection: false,
    ...over,
  });
}

describe("xtermHandlesKey", () => {
  it("leaves plain printable keys to the beforeinput interceptor", () => {
    expect(decide({ key: "a" })).toBe(false);
    expect(decide({ key: " " })).toBe(false);
    expect(decide({ key: "/" })).toBe(false);
  });

  it("handles keyup events", () => {
    expect(decide({ type: "keyup", key: "a" })).toBe(true);
    expect(decide({ type: "keyup", key: "v", meta: true })).toBe(true);
  });

  it("leaves a plain printable keypress to the beforeinput interceptor, so xterm never sends it too", () => {
    expect(decide({ type: "keypress", key: "a" })).toBe(false);
    expect(decide({ type: "keypress", key: " " })).toBe(false);
    expect(decide({ type: "keypress", key: "a", kittyFlags: 5 })).toBe(false);
  });

  it("leaves a plain dead-key keydown to the browser, so xterm never waits for a keypress that doesn't come", () => {
    expect(decide({ key: "Dead" })).toBe(false);
    expect(decide({ key: "Dead", kittyFlags: 5 })).toBe(false);
  });

  it("leaves a ⌃ or ⌘ dead-key keydown to the browser too", () => {
    expect(decide({ key: "Dead", meta: true })).toBe(false);
    expect(decide({ key: "Dead", ctrl: true })).toBe(false);
  });

  it("handles a dead key held with ⌥ and a dead-key keyup", () => {
    expect(decide({ key: "Dead", alt: true })).toBe(true);
    expect(decide({ type: "keyup", key: "Dead" })).toBe(true);
  });

  it("handles a keypress xterm owns on keydown", () => {
    expect(decide({ type: "keypress", key: "a", kittyFlags: 13 })).toBe(true);
    expect(decide({ type: "keypress", key: "a", composing: true })).toBe(true);
    expect(decide({ type: "keypress", key: "o", alt: true })).toBe(true);
    expect(decide({ type: "keypress", key: "Enter" })).toBe(true);
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
    expect(decide({ key: "a", kittyFlags: 13 })).toBe(true);
    expect(decide({ key: "a", kittyFlags: 31 })).toBe(true);
  });

  it("leaves plain printable keys to the beforeinput interceptor under other kitty flags", () => {
    expect(decide({ key: "a", kittyFlags: 5 })).toBe(false);
    expect(decide({ key: "a", kittyFlags: 1 })).toBe(false);
    expect(decide({ key: "a", kittyFlags: 16 })).toBe(false);
  });

  it("leaves ⌘V to the browser so the Edit menu's Paste fires", () => {
    expect(decide({ key: "v", meta: true })).toBe(false);
    expect(decide({ key: "V", meta: true })).toBe(false);
    expect(decide({ key: "v", meta: true, kittyFlags: 5 })).toBe(false);
  });

  it("leaves ⌘C to the browser when the terminal has a selection, so the Edit menu's Copy fires", () => {
    expect(decide({ key: "c", meta: true, hasSelection: true })).toBe(false);
    expect(decide({ key: "C", meta: true, hasSelection: true, kittyFlags: 5 })).toBe(false);
  });

  it("handles ⌘C without a selection, and ⌃/⌥⌘ chords, but stands aside for other kitty ⌘ chords", () => {
    expect(decide({ key: "c", meta: true, hasSelection: false, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "c", meta: true, ctrl: true, hasSelection: true })).toBe(true);
    expect(decide({ key: "c", meta: true, alt: true, hasSelection: true })).toBe(true);
    expect(decide({ key: "a", meta: true, hasSelection: true })).toBe(true);
    expect(decide({ key: "s", meta: true, hasSelection: true, kittyFlags: 5 })).toBe(false);
  });

  it("handles ⌘C without a selection under a kitty program, and every ⌘ chord in legacy mode", () => {
    expect(decide({ key: "c", meta: true, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "s", meta: true, kittyFlags: 5 })).toBe(false);
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

  // #171: a kitty program encodes ⌘Q as ESC[113;9u and preventDefaults it, so
  // WebKit never re-sends the keydown to the native menu and the hold-to-quit
  // guard — like Hide, Minimize and Select All — never fires.
  it("S30 — stands aside for every ⌘ chord on a character key under a kitty program", () => {
    for (const kittyFlags of [1, 5]) {
      expect(decide({ key: "q", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "h", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "m", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "a", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "t", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "Q", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "q", meta: true, alt: true, kittyFlags })).toBe(false);
      expect(decide({ key: "f", meta: true, ctrl: true, kittyFlags })).toBe(false);
      expect(decide({ key: "s", meta: true, kittyFlags })).toBe(false);
      expect(decide({ key: "s", meta: true, hasSelection: true, kittyFlags })).toBe(false);
    }
  });

  it("S31 — keeps only plain ⌘C without a selection, and leaves named keys alone", () => {
    expect(decide({ key: "c", meta: true, hasSelection: false, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "c", meta: true, alt: true, hasSelection: false, kittyFlags: 5 })).toBe(
      false,
    );
    expect(decide({ key: "v", meta: true, kittyFlags: 5 })).toBe(false);
    expect(decide({ key: "c", meta: true, hasSelection: true, kittyFlags: 5 })).toBe(false);
    expect(decide({ key: "C", meta: true, hasSelection: false, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "Enter", meta: true, kittyFlags: 5 })).toBe(true);
    expect(decide({ key: "Meta", meta: true, kittyFlags: 8 })).toBe(true);
  });

  it("S32 — legacy mode keeps every ⌘ chord", () => {
    expect(decide({ key: "q", meta: true })).toBe(true);
    expect(decide({ key: "a", meta: true })).toBe(true);
    expect(decide({ key: "v", meta: true, ctrl: true })).toBe(true);
    expect(decide({ key: "v", meta: true, alt: true })).toBe(true);
  });

  it("S33 — a composing or keyup ⌘ chord is still xterm's under a kitty program", () => {
    expect(decide({ key: "q", meta: true, composing: true, kittyFlags: 5 })).toBe(true);
    expect(decide({ type: "keyup", key: "q", meta: true, kittyFlags: 5 })).toBe(true);
  });
});
