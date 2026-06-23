// Tests for the pure card-resize geometry (corner math + min-size clamp). Net-new
// — CardView.resized lived in the untested AppKit layer.

import { describe, it, expect } from "vitest";
import { resizeFrame, MIN_CARD_W, MIN_CARD_H } from "./resize";

describe("resizeFrame", () => {
  it("grows from the bottom-right corner", () => {
    expect(resizeFrame({ x: 0, y: 0, w: 200, h: 100 }, "br", 50, 30)).toEqual({ x: 0, y: 0, w: 250, h: 130 });
  });

  it("clamps the bottom-right corner at the minimum size", () => {
    expect(resizeFrame({ x: 0, y: 0, w: 200, h: 100 }, "br", -300, -300)).toEqual({
      x: 0,
      y: 0,
      w: MIN_CARD_W,
      h: MIN_CARD_H,
    });
  });

  it("moves x/y when dragging the top-left corner", () => {
    expect(resizeFrame({ x: 100, y: 100, w: 200, h: 100 }, "tl", -50, -20)).toEqual({
      x: 50,
      y: 80,
      w: 250,
      h: 120,
    });
  });

  it("clamps the top-left corner and pins the opposite (right/bottom) edge", () => {
    expect(resizeFrame({ x: 100, y: 100, w: 200, h: 100 }, "tl", 300, 300)).toEqual({
      x: 140,
      y: 110,
      w: MIN_CARD_W,
      h: MIN_CARD_H,
    });
  });
});
