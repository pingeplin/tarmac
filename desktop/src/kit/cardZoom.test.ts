import { describe, it, expect } from "vitest";
import { cardIframePx, cardGestureScale, MAGNIFY_K } from "./cardZoom";
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
