// Tests for the doc-card placement port (firstFreeSlot + scatter). Mirrors the
// Swift app's `Place` constants and the first-free-slot grid search behaviour.

import { describe, it, expect } from "vitest";
import { Place, firstFreeSlot, scatterFrame, rectsIntersect } from "./placement";
import type { Rect } from "./geom";

const owner: Rect = { ...Place.termFrame };

describe("rectsIntersect", () => {
  it("is true for overlap, false for touching edges (half-open)", () => {
    expect(rectsIntersect({ x: 0, y: 0, w: 10, h: 10 }, { x: 5, y: 5, w: 10, h: 10 })).toBe(true);
    // shared edge only — CGRect.intersects treats this as NOT intersecting
    expect(rectsIntersect({ x: 0, y: 0, w: 10, h: 10 }, { x: 10, y: 0, w: 10, h: 10 })).toBe(false);
    expect(rectsIntersect({ x: 0, y: 0, w: 10, h: 10 }, { x: 20, y: 0, w: 10, h: 10 })).toBe(false);
  });
});

describe("firstFreeSlot", () => {
  it("places the first doc at the anchor (owner right + gapX, owner top)", () => {
    const f = firstFreeSlot(owner, []);
    expect(f).toEqual({
      x: owner.x + owner.w + Place.gapX,
      y: owner.y,
      w: Place.docW,
      h: Place.docH,
    });
  });

  it("skips the next column when the anchor slot is occupied", () => {
    const first = firstFreeSlot(owner, []);
    const second = firstFreeSlot(owner, [first]);
    // second lands one (docW+gapX) to the right, same row
    expect(second).toEqual({
      x: first.x + Place.docW + Place.gapX,
      y: first.y,
      w: Place.docW,
      h: Place.docH,
    });
    expect(rectsIntersect(first, second)).toBe(false);
  });

  it("honours the 8px collision inset (a near-miss still counts as occupied)", () => {
    const first = firstFreeSlot(owner, []);
    // an existing card 4px to the right of the anchor's right edge is within the
    // 8px inset, so the anchor slot must be considered occupied.
    const near: Rect = { x: first.x + 4, y: first.y, w: Place.docW, h: Place.docH };
    const placed = firstFreeSlot(owner, [near]);
    expect(placed.x).not.toBe(first.x); // anchor rejected
  });

  it("wraps to the next row when a row fills up", () => {
    // Occupy the entire first row by faking wide coverage: place blockers across
    // the first few columns and assert the result drops to row 1 once col 0..N are full.
    const anchorX = owner.x + owner.w + Place.gapX;
    const rowBlockers: Rect[] = [];
    for (let col = 0; col < Place.scanCols; col++) {
      rowBlockers.push({
        x: anchorX + col * (Place.docW + Place.gapX),
        y: owner.y,
        w: Place.docW,
        h: Place.docH,
      });
    }
    const placed = firstFreeSlot(owner, rowBlockers);
    expect(placed.y).toBe(owner.y + Place.docH + Place.gapY); // row 1
    expect(placed.x).toBe(anchorX); // back to col 0
  });
});

describe("scatterFrame (M1 migration)", () => {
  it("fills a 2-column grid right of the terminal", () => {
    const s0 = scatterFrame(0);
    const s1 = scatterFrame(1);
    const s2 = scatterFrame(2);
    const baseX = Place.termFrame.x + Place.termFrame.w + Place.gapX;
    expect(s0).toEqual({ x: baseX, y: Place.termFrame.y, w: Place.docW, h: Place.docH });
    // slot 1 → col 1, same row
    expect(s1.x).toBe(baseX + Place.docW + Place.gapX);
    expect(s1.y).toBe(Place.termFrame.y);
    // slot 2 → col 0, row 1
    expect(s2.x).toBe(baseX);
    expect(s2.y).toBe(Place.termFrame.y + Place.docH + Place.gapY);
  });
});
