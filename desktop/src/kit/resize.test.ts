// Tests for the pure card-resize geometry (edge + corner math, per-axis min clamp).

import { describe, it, expect } from "vitest";
import { resizeFrame, MIN_CARD_W, MIN_CARD_H } from "./resize";

const START = { x: 0, y: 0, w: 200, h: 200 };

describe("resizeFrame — edge handles (single-axis)", () => {
  // S1: right edge — width grows, all other fields unchanged
  it("r: grows width rightward, origin and height untouched", () => {
    const { x, y, w, h } = resizeFrame(START, "r", 50, 99);
    expect(w).toBe(250);
    expect(x).toBe(START.x);
    expect(y).toBe(START.y);
    expect(h).toBe(START.h);
  });

  // S2: left edge — origin shifts left, width grows, y and h untouched
  it("l: shifts origin left, grows width, y and h untouched", () => {
    const { x, y, w, h } = resizeFrame(START, "l", -50, 99);
    expect(x).toBe(-50);
    expect(w).toBe(250);
    expect(y).toBe(START.y);
    expect(h).toBe(START.h);
  });

  // S3: bottom edge — height grows, x, y, w untouched
  it("b: grows height downward, x, y, w untouched", () => {
    const { x, y, w, h } = resizeFrame(START, "b", 99, 50);
    expect(h).toBe(250);
    expect(x).toBe(START.x);
    expect(y).toBe(START.y);
    expect(w).toBe(START.w);
  });

  // S4: top edge — origin shifts up, height grows, x and w untouched
  it("t: shifts origin up, grows height, x and w untouched", () => {
    const { x, y, w, h } = resizeFrame(START, "t", 99, -50);
    expect(y).toBe(-50);
    expect(h).toBe(250);
    expect(x).toBe(START.x);
    expect(w).toBe(START.w);
  });
});

describe("resizeFrame — corner handles (dual-axis regression)", () => {
  // S5: corners must produce the same origin-shift + opposite-edge-pinned behavior
  // as before the Handle generalization.
  it("br: grows both axes, origin unchanged", () => {
    const f = resizeFrame({ x: 0, y: 0, w: 200, h: 100 }, "br", 50, 30);
    expect(f).toEqual({ x: 0, y: 0, w: 250, h: 130 });
  });

  it("tl: shifts origin on both axes, opposite edges pinned", () => {
    const f = resizeFrame({ x: 100, y: 100, w: 200, h: 100 }, "tl", -50, -20);
    expect(f).toEqual({ x: 50, y: 80, w: 250, h: 120 });
  });

  it("tr: shifts y, grows w rightward, x unchanged", () => {
    const f = resizeFrame({ x: 0, y: 0, w: 200, h: 200 }, "tr", 50, -30);
    expect(f).toEqual({ x: 0, y: -30, w: 250, h: 230 });
  });

  it("bl: shifts x, grows h downward, y unchanged", () => {
    const f = resizeFrame({ x: 0, y: 0, w: 200, h: 200 }, "bl", -30, 50);
    expect(f).toEqual({ x: -30, y: 0, w: 230, h: 250 });
  });
});

describe("resizeFrame — per-axis min clamp", () => {
  // S6: top handle past min height — clamps h, pins bottom, w/x untouched
  it("t past min height: clamps h to MIN_CARD_H, pins bottom edge, w/x unchanged", () => {
    const { x, y, w, h } = resizeFrame(START, "t", 99, 150);
    expect(h).toBe(MIN_CARD_H);
    expect(y).toBe(START.y + (START.h - MIN_CARD_H));
    expect(w).toBe(START.w);
    expect(x).toBe(START.x);
  });

  // S7: left handle past min width — clamps w, pins right edge, h/y untouched
  it("l past min width: clamps w to MIN_CARD_W, pins right edge, h/y unchanged", () => {
    const { x, y, w, h } = resizeFrame(START, "l", 100, 99);
    expect(w).toBe(MIN_CARD_W);
    expect(x).toBe(START.x + (START.w - MIN_CARD_W));
    expect(h).toBe(START.h);
    expect(y).toBe(START.y);
  });

  // S8: right handle past min width — clamps w, origin unchanged
  it("r past min width: clamps w to MIN_CARD_W, origin unchanged", () => {
    const { x, y, w, h } = resizeFrame(START, "r", -100, 99);
    expect(w).toBe(MIN_CARD_W);
    expect(x).toBe(START.x);
    expect(y).toBe(START.y);
    expect(h).toBe(START.h);
  });

  it("br clamps both axes at once, origin unchanged", () => {
    const f = resizeFrame({ x: 0, y: 0, w: 200, h: 100 }, "br", -300, -300);
    expect(f).toEqual({ x: 0, y: 0, w: MIN_CARD_W, h: MIN_CARD_H });
  });

  it("tl clamps both axes and pins opposite (right/bottom) edge", () => {
    const f = resizeFrame({ x: 100, y: 100, w: 200, h: 100 }, "tl", 300, 300);
    expect(f).toEqual({ x: 140, y: 110, w: MIN_CARD_W, h: MIN_CARD_H });
  });

  // S16: width axis clamps independently; right edge pinned at 300 → x = 300 - MIN_CARD_W = 140
  it("tl: width axis clamps to MIN_CARD_W while height grows freely, right edge pinned", () => {
    const f = resizeFrame({ x: 100, y: 100, w: 200, h: 100 }, "tl", 300, -20);
    expect(f).toEqual({ x: 140, y: 80, w: MIN_CARD_W, h: 120 });
  });

  // S17: zero delta is identity for any handle
  it("zero delta: returns start frame unchanged for edge and corner handles", () => {
    expect(resizeFrame(START, "r", 0, 0)).toEqual(START);
    expect(resizeFrame(START, "tl", 0, 0)).toEqual(START);
  });
});
