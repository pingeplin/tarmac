import { describe, it, expect } from "vitest";
import { bytes, type TermKeyInput } from "./termKeyBinding";

// Port of TermKeyBindingTests.swift (2606.0007 / issue #21) — the pure decider
// for Ghostty-parity macOS line-editing keys in a terminal card. The Swift spec
// drove physical Carbon keyCodes + raw NSEvent modifier bits; the DOM rewrite
// drives `KeyboardEvent.code` + boolean intent modifiers. CapsLock was an
// explicit bit in the Swift matrix (always-irrelevant); here it has no field at
// all, so the CapsLock-invariance cases (S6) become identity assertions on the
// surviving inputs — there is no CapsLock knob to flip, which is exactly the
// guarantee. Every Swift case/assertion is reproduced.

// Build a decision input with everything off, overridden by `over`.
function decide(over: Partial<TermKeyInput>): number[] | null {
  return bytes({
    code: "",
    meta: false,
    alt: false,
    ctrl: false,
    shift: false,
    composing: false,
    kittyActive: false,
    ...over,
  });
}

// Expected byte sequences (identical to the Swift constants).
const ctrlU = [0x15];
const ctrlA = [0x01];
const ctrlE = [0x05];
const optUp = [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x41]; // ESC[1;3A
const optDown = [0x1b, 0x5b, 0x31, 0x3b, 0x33, 0x42]; // ESC[1;3B
const optLeft = [0x1b, 0x62]; // ESC b (backward-word)
const optRight = [0x1b, 0x66]; // ESC f (forward-word)

describe("TermKeyBinding", () => {
  // Happy path — Ghostty byte parity (S1–S5)
  it("⌘⌫ sends Ctrl-U", () => {
    // S1
    expect(decide({ code: "Backspace", meta: true })).toEqual(ctrlU);
  });
  it("⌘← sends Ctrl-A", () => {
    // S2
    expect(decide({ code: "ArrowLeft", meta: true })).toEqual(ctrlA);
  });
  it("⌘→ sends Ctrl-E", () => {
    // S3
    expect(decide({ code: "ArrowRight", meta: true })).toEqual(ctrlE);
  });
  it("⌥↑ sends ESC[1;3A", () => {
    // S4
    expect(decide({ code: "ArrowUp", alt: true })).toEqual(optUp);
  });
  it("⌥↓ sends ESC[1;3B", () => {
    // S5
    expect(decide({ code: "ArrowDown", alt: true })).toEqual(optDown);
  });
  it("⌥← sends ESC b (backward-word)", () => {
    // S15
    expect(decide({ code: "ArrowLeft", alt: true })).toEqual(optLeft);
  });
  it("⌥→ sends ESC f (forward-word)", () => {
    // S16
    expect(decide({ code: "ArrowRight", alt: true })).toEqual(optRight);
  });

  // CapsLock invariance — all five rows (S6). In the DOM shape CapsLock is not an
  // intent modifier and has no input field, so there is nothing to toggle: the
  // recognized rows simply still produce their bytes. This preserves the Swift
  // guarantee (CapsLock can never change the outcome) by construction.
  it("CapsLock never changes outcome (no CapsLock knob — rows still fire)", () => {
    // S6
    expect(decide({ code: "Backspace", meta: true })).toEqual(ctrlU);
    expect(decide({ code: "ArrowLeft", meta: true })).toEqual(ctrlA);
    expect(decide({ code: "ArrowRight", meta: true })).toEqual(ctrlE);
    expect(decide({ code: "ArrowUp", alt: true })).toEqual(optUp);
    expect(decide({ code: "ArrowDown", alt: true })).toEqual(optDown);
  });

  // Exact-modifier gating (S7–S8)
  it("⌘ rows defer when any extra intent modifier is held", () => {
    // S7 — ⌃⌘←, ⌥⌘←, ⇧⌘← stay super; checked across the ⌘⌫ and ⌘→ rows too.
    expect(decide({ code: "ArrowLeft", meta: true, ctrl: true })).toBeNull();
    expect(decide({ code: "ArrowLeft", meta: true, alt: true })).toBeNull();
    expect(decide({ code: "ArrowLeft", meta: true, shift: true })).toBeNull();
    expect(decide({ code: "Backspace", meta: true, ctrl: true })).toBeNull(); // ⌘⌫ row
    expect(decide({ code: "ArrowRight", meta: true, shift: true })).toBeNull(); // ⌘→ row
  });
  it("⌥ rows defer when shift is also held", () => {
    // S8 — ⇧⌥↑ / ⇧⌥↓ (both ⌥ rows)
    expect(decide({ code: "ArrowUp", alt: true, shift: true })).toBeNull();
    expect(decide({ code: "ArrowDown", alt: true, shift: true })).toBeNull();
  });
  it("⌥←/⌥→ rows defer when shift is also held", () => {
    // S17 — ⇧⌥← / ⇧⌥→
    expect(decide({ code: "ArrowLeft", alt: true, shift: true })).toBeNull();
    expect(decide({ code: "ArrowRight", alt: true, shift: true })).toBeNull();
  });

  // IME & kitty gates (S9–S10) — paired bytes-off / null-on on identical input.
  it("composing defers (across a ⌘ and a ⌥ row)", () => {
    // S9
    expect(decide({ code: "Backspace", meta: true, composing: false })).toEqual(ctrlU);
    expect(decide({ code: "Backspace", meta: true, composing: true })).toBeNull();
    expect(decide({ code: "ArrowUp", alt: true, composing: false })).toEqual(optUp);
    expect(decide({ code: "ArrowUp", alt: true, composing: true })).toBeNull();
  });
  it("kittyActive defers (across a ⌘ and a ⌥ row)", () => {
    // S10
    expect(decide({ code: "Backspace", meta: true, kittyActive: false })).toEqual(ctrlU);
    expect(decide({ code: "Backspace", meta: true, kittyActive: true })).toBeNull();
    expect(decide({ code: "ArrowUp", alt: true, kittyActive: false })).toEqual(optUp);
    expect(decide({ code: "ArrowUp", alt: true, kittyActive: true })).toBeNull();
  });
  it("composing/kittyActive defer the ⌥←/⌥→ rows too", () => {
    // S18
    expect(decide({ code: "ArrowLeft", alt: true, composing: false })).toEqual(optLeft);
    expect(decide({ code: "ArrowLeft", alt: true, composing: true })).toBeNull();
    expect(decide({ code: "ArrowRight", alt: true, kittyActive: false })).toEqual(optRight);
    expect(decide({ code: "ArrowRight", alt: true, kittyActive: true })).toBeNull();
  });

  // No-regression — keys that must stay xterm.js's (S11–S14)
  it("⌃←/→ defer (claimed by macOS Mission Control)", () => {
    // S19 (was S11 — the ⌥←/⌥→ half of this scenario is superseded by S15/S16:
    // xterm.js's own handling for those turned out not to word-jump, see issue #61)
    expect(decide({ code: "ArrowLeft", ctrl: true })).toBeNull();
    expect(decide({ code: "ArrowRight", ctrl: true })).toBeNull();
  });
  it("⌥⌫ word delete defers", () => {
    // S12 — ⌫ under option, not meta
    expect(decide({ code: "Backspace", alt: true })).toBeNull();
  });
  it("plain ⌫ and plain arrows defer", () => {
    // S13
    expect(decide({ code: "Backspace" })).toBeNull();
    expect(decide({ code: "ArrowLeft" })).toBeNull();
    expect(decide({ code: "ArrowRight" })).toBeNull();
    expect(decide({ code: "ArrowUp" })).toBeNull();
    expect(decide({ code: "ArrowDown" })).toBeNull();
  });
  it("unrecognized codes defer even with ⌘ held", () => {
    // S14 — guards the default branch
    expect(decide({ code: "KeyA", meta: true })).toBeNull(); // 'a'
    expect(decide({ code: "Enter", meta: true })).toBeNull(); // Return
  });
});
