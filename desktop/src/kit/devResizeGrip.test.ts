import { describe, it, expect } from "vitest";
import { gripDelta, gripPlan } from "./devResizeGrip";

describe("S43 — the delta is board units scaled INTO screen px", () => {
  it("multiplies by zoom, because CardShell divides by it", () => {
    // CardShell.onHandlePointerMove computes `dx = (e.clientX − s.px) / zoom`, so
    // a plan that omits zoom here returns 200 and resizes to the wrong size.
    // Asymmetric FIRST: every dx === dy row below is also satisfied by an
    // implementation that swaps the two axes.
    expect(gripDelta({ w: 600, h: 400 }, { w: 800, h: 500 }, 0.5)).toEqual({ dx: 100, dy: 50 });
    expect(gripDelta({ w: 600, h: 400 }, { w: 800, h: 600 }, 0.5)).toEqual({ dx: 100, dy: 100 });
    expect(gripDelta({ w: 600, h: 400 }, { w: 800, h: 600 }, 1)).toEqual({ dx: 200, dy: 200 });
    expect(gripDelta({ w: 800, h: 600 }, { w: 600, h: 400 }, 2)).toEqual({ dx: -400, dy: -400 });
  });
});

describe("S44 — the grip drag is three pointer events on the grip itself", () => {
  const plan = gripPlan({ x: 300, y: 200 }, { dx: 100, dy: 50 });

  it("presses at the centre, moves to centre+delta, releases there", () => {
    // clientX/clientY BY VALUE on all three: those are the only fields the resize
    // reads (CardShell.tsx: `dx = (e.clientX − s.px) / zoom`), so a plan that set
    // screenX/screenY instead would dispatch a zero-delta drag and resize nothing.
    // `button: 0` is read too (CardShell returns early on `e.button !== 0`);
    // `buttons` is carried for fidelity and nothing reads it.
    const shared = { pointerId: 1, pointerType: "mouse", isPrimary: true, button: 0, bubbles: true, cancelable: true };
    expect(plan).toEqual([
      { type: "pointerdown", clientX: 300, clientY: 200, buttons: 1, ...shared },
      { type: "pointermove", clientX: 400, clientY: 250, buttons: 1, ...shared },
      { type: "pointerup", clientX: 400, clientY: 250, buttons: 0, ...shared },
    ]);
  });

  it("uses pointer id 1, without which CardShell's handler aborts before the grab", () => {
    // Not cosmetic. CardShell calls setPointerCapture(e.pointerId) BEFORE recording
    // the grab, and WebKit throws NotFoundError for an id no pointer ever had —
    // measured (#174 pre-check 4): 2 and 99 throw, 1 does not, because 1 is the
    // mouse's reserved id. Capture still never happens (hasPointerCapture reads
    // false inside the handler), which is fine: all three events land on the same
    // element, where CardShell's own move/up listeners are.
    expect(plan.map((d) => d.pointerId)).toEqual([1, 1, 1]);
    expect(new Set(plan.map((d) => d.type)).size).toBe(3);
  });
});
