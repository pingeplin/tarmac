import { describe, it, expect } from "vitest";
import {
  cardIframePx,
  cardGestureScale,
  cardScrollDelta,
  quantizeScrollDelta,
  relayScrollStep,
  createScrollRelay,
  MAGNIFY_K,
} from "./cardZoom";
import { MAX_ZOOM } from "../board/BoardEngine";

// Spec 2607.0006 — MAGNIFY_K's docstring asserts this; nothing else enforced it.
// K >= MAX_ZOOM is what makes scale(zoom/K) a DOWN-scale across the whole range,
// so the frozen-K layout is never bitmap-upscaled. Imported from BoardEngine so
// raising MAX_ZOOM above K fails here.
describe("MAGNIFY_K never upsamples", () => {
  it("is >= the engine MAX_ZOOM", () => {
    expect(MAGNIFY_K).toBeGreaterThanOrEqual(MAX_ZOOM);
  });

  it("at max zoom the card scale factor is <= 1", () => {
    expect(MAX_ZOOM / MAGNIFY_K).toBeLessThanOrEqual(1);
  });
});

// Spec 2607.0004 S10 — settled real-px box and mid-gesture scale.
describe("cardIframePx (S10)", () => {
  it("is the frame times zoom, rounded", () => {
    expect(cardIframePx({ w: 640, h: 400 }, 1)).toEqual({ w: 640, h: 400 });
    expect(cardIframePx({ w: 640, h: 400 }, 1.5)).toEqual({ w: 960, h: 600 });
  });

  // Rounds, not truncates — a truncation bug would produce 100 here.
  // (1.005 is avoided: it isn't exactly representable as a double, so
  // 100 * 1.005 == 100.49999999999999 and rounds down — a float trap, not
  // a rounding-vs-truncation distinction.)
  it("rounds non-integer products", () => {
    expect(cardIframePx({ w: 100, h: 100 }, 1.006)).toEqual({ w: 101, h: 101 });
    expect(cardIframePx({ w: 100, h: 100 }, 0.994)).toEqual({ w: 99, h: 99 });
  });
});

describe("cardGestureScale (S10)", () => {
  it("is live zoom over settled zoom", () => {
    expect(cardGestureScale(2, 1)).toBe(2);
    expect(cardGestureScale(0.5, 1)).toBe(0.5);
    expect(cardGestureScale(1.5, 1.5)).toBe(1);
  });
});

// Spec 2609.0013 (#142) — why the carry exists is on quantizeScrollDelta itself.
// These assert VALUES, not mere integrality: the contract pins round-to-nearest,
// and integrality alone leaves truncate, floor, ceil and a 2-px grid passing.
describe("quantizeScrollDelta (2609.0013)", () => {
  it("passes a whole delta through untouched (S1)", () => {
    expect(quantizeScrollDelta(35, 0)).toEqual({ step: 35, carry: 0 });
    expect(quantizeScrollDelta(0, 0)).toEqual({ step: 0, carry: 0 });
  });

  // Ties are reachable (zoom 2.0, a 35px notch -> 17.5) and three tie-only mutants
  // pass every other assertion here, so the contract's tie rule needs its own test.
  it("resolves ties by Math.round, including its negative asymmetry (contract)", () => {
    expect(quantizeScrollDelta(2.5, 0).step).toBe(3);
    expect(quantizeScrollDelta(-2.5, 0).step).toBe(-2);
  });

  it("emits an integer step whenever the total is fractional (S2)", () => {
    expect(quantizeScrollDelta(34.72, 0).step).toBe(35);
    expect(quantizeScrollDelta(35, 0.72).step).toBe(36);
  });

  // The prefix bound is the no-drift claim: a carry-less implementation is off by
  // ~0.28 px per event here, so it breaches 1 px by the fourth event.
  it("keeps every prefix sum within 1px of exact travel (S3)", () => {
    const d = 34.72;
    const N = 100;
    let carry = 0;
    let travelled = 0;
    for (let n = 1; n <= N; n++) {
      const q = quantizeScrollDelta(d, carry);
      expect(Number.isInteger(q.step)).toBe(true);
      travelled += q.step;
      carry = q.carry;
      // <= 1, not < 1: stated as a bound on the accumulated error rather than
      // re-deriving the 0.5 px that round-to-nearest actually achieves.
      expect(Math.abs(travelled - n * d)).toBeLessThanOrEqual(1);
    }
    expect(travelled + carry).toBeCloseTo(N * d, 9);
  });

  it("advances within ceil(1/d)+1 events on sub-pixel deltas (S4)", () => {
    const d = 0.4;
    const budget = Math.ceil(1 / d) + 1;
    let carry = 0;
    let travelled = 0;
    for (let i = 0; i < budget; i++) {
      const q = quantizeScrollDelta(d, carry);
      expect(Number.isInteger(q.step)).toBe(true);
      // Never backwards: a clamp that forces |step| >= 1 jitters the card
      // against the drag direction on a slow trackpad.
      expect(q.step).toBeGreaterThanOrEqual(0);
      travelled += q.step;
      carry = q.carry;
    }
    expect(travelled).toBeGreaterThanOrEqual(1);
    const before = travelled;
    for (let i = 0; i < budget; i++) {
      const q = quantizeScrollDelta(d, carry);
      travelled += q.step;
      carry = q.carry;
    }
    expect(travelled).toBeGreaterThan(before);
  });

  // The carry must be CONSUMED, not merely stored. An equal-and-opposite pair
  // cannot show that: the residue cancels either way, so an implementation that
  // tracks the carry and never applies it passes. Hence the small reverse delta,
  // which only crosses a pixel because of the inherited residue. Do not
  // "simplify" this back to equal magnitudes (spec 2609.0013 S5).
  it("consumes the carry on a direction reversal (S5)", () => {
    const down = quantizeScrollDelta(34.72, 0);
    const up = quantizeScrollDelta(-0.3, down.carry);
    expect(up.step).toBe(-1);

    // Secondary, weaker: an equal-and-opposite reversal must not compound.
    const back = quantizeScrollDelta(-34.72, down.carry);
    expect(down.step + back.step).toBe(0);
  });

  // Only above 1px: -0.4 may legitimately quantize to step 0 with the residue
  // carried, so the sign claim does not hold below that.
  it("preserves direction for deltas of at least 1px (S6)", () => {
    for (const d of [-1.2, -34.72, -1000.5]) {
      const q = quantizeScrollDelta(d, 0);
      expect(Number.isInteger(q.step)).toBe(true);
      expect(q.step).toBeLessThan(0);
    }
  });

  it("creates and destroys no travel across input classes (S7)", () => {
    for (const d of [0, 12, 34.72, -34.72, 1234.567]) {
      for (const c of [0, 0.42, -0.42]) {
        const q = quantizeScrollDelta(d, c);
        expect(Number.isInteger(q.step)).toBe(true);
        expect(q.step + q.carry).toBeCloseTo(d + c, 9);
      }
    }
  });

  // Rules out an implementation that satisfies S7 by parking whole pixels in the
  // carry and never scrolling.
  it("never carries a whole pixel (S9)", () => {
    for (const d of [0, 12, 34.72, -34.72, 0.4, -0.4, 1234.567]) {
      for (const c of [0, 0.99, -0.99]) {
        expect(Math.abs(quantizeScrollDelta(d, c).carry)).toBeLessThan(1);
      }
    }
  });
});

// Spec 2609.0013 S11-S14 — the relay's own decisions. Inline in the wheel handler
// these were invisible: mutating the carry write-back, the &&, or the axis pairing
// each left the full suite green.
describe("relayScrollStep (2609.0013)", () => {
  it("writes both axes' carries back (S11)", () => {
    const r = relayScrollStep(34.72, 12.4, 0, 0);
    expect(r.carryX).toBeCloseTo(quantizeScrollDelta(34.72, 0).carry, 12);
    expect(r.carryY).toBeCloseTo(quantizeScrollDelta(12.4, 0).carry, 12);
  });

  it("still posts when only one axis quantizes to zero (S12)", () => {
    expect(relayScrollStep(0.2, 34.72, 0, 0).post).toBe(true);
    expect(relayScrollStep(34.72, 0.2, 0, 0).post).toBe(true);
  });

  // The carry must survive a suppressed post, or a slow drag never accumulates.
  it("suppresses the post only when both axes are zero, keeping the carry (S13)", () => {
    const r = relayScrollStep(0.2, 0.2, 0, 0);
    expect(r.post).toBe(false);
    expect(r.dx).toBe(0);
    expect(r.dy).toBe(0);
    expect(r.carryX).toBeCloseTo(0.2, 12);
    expect(r.carryY).toBeCloseTo(0.2, 12);
  });

  it("keeps each axis on its own delta (S14)", () => {
    const r = relayScrollStep(30.4, -12.6, 0, 0);
    expect(r.dx).toBe(30);
    expect(r.dy).toBe(-13);
  });
});

// Spec 2609.0013 S15 — the carry must survive a suppressed post. This is the
// ordering that was previously inline in the component, where reversing it
// stalled slow scrolls forever with the whole suite still green.
describe("createScrollRelay (2609.0013)", () => {
  it("accumulates across suppressed posts until it crosses a pixel (S15)", () => {
    const relay = createScrollRelay();
    const seen = [];
    for (let i = 0; i < 5; i++) seen.push(relay(0, 0.3));
    expect(seen.filter((r) => r.post).length).toBeGreaterThan(0);
    expect(seen.reduce((n, r) => n + r.dy, 0)).toBeGreaterThanOrEqual(1);
  });

  // Two cards scroll independently: advancing one must not move the other's
  // residue, so a fresh relay's first step matches any other relay's first step.
  it("keeps each handler's carry independent", () => {
    const a = createScrollRelay();
    const b = createScrollRelay();
    const aFirst = a(0, 0.6);
    a(0, 0.6);
    a(0, 0.6);
    expect(b(0, 0.6)).toEqual(aFirst);
  });
});

// The composition the wheel relay actually performs. S3 already pins the drift
// bound; what this adds is the real-world premise — at a non-integer board zoom
// the unit conversion alone yields a fraction, and the relay must absorb it.
describe("relay composition at a non-integer board zoom (2609.0013)", () => {
  it("turns a real wheel notch into whole document px at zoom 1.728", () => {
    const zoom = 1.728;
    expect(Number.isInteger(cardScrollDelta(60, zoom, true))).toBe(false);
    expect(Number.isInteger(createScrollRelay()(0, cardScrollDelta(60, zoom, true)).dy)).toBe(true);
  });
});
