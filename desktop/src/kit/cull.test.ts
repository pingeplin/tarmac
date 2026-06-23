// Tests for viewport culling (perf fix #5): the visible-world rect and the
// per-card visibility predicate, with the Swift 1-viewport margin.

import { describe, it, expect } from "vitest";
import { visibleWorldRect, isCardVisible, type Viewport } from "./cull";
import type { Rect } from "./geom";

const VW = 1000;
const VH = 600;

describe("visibleWorldRect", () => {
  it("at zoom 1 spans the viewport plus 1 viewport margin per side", () => {
    const vp: Viewport = { zoom: 1, cx: 0, cy: 0 };
    const r = visibleWorldRect(vp, VW, VH, 1);
    // half = visW/2 + 1*visW = 1.5*visW ; full width = 3*visW
    expect(r.w).toBe(3 * VW);
    expect(r.h).toBe(3 * VH);
    expect(r.x).toBe(-1.5 * VW);
    expect(r.y).toBe(-1.5 * VH);
  });

  it("zoom < 1 widens the world region (more world on screen)", () => {
    const r = visibleWorldRect({ zoom: 0.5, cx: 0, cy: 0 }, VW, VH, 1);
    expect(r.w).toBe(3 * (VW / 0.5));
  });

  it("re-centers on the viewport center", () => {
    const r = visibleWorldRect({ zoom: 1, cx: 200, cy: 100 }, VW, VH, 0);
    expect(r.x).toBe(200 - VW / 2);
    expect(r.y).toBe(100 - VH / 2);
  });
});

describe("isCardVisible", () => {
  const vp: Viewport = { zoom: 1, cx: 0, cy: 0 };

  it("shows a card at the viewport center", () => {
    const card: Rect = { x: -50, y: -50, w: 100, h: 100 };
    expect(isCardVisible(card, vp, VW, VH, 1)).toBe(true);
  });

  it("keeps a card within the 1-viewport margin visible (no pop-in)", () => {
    // just inside the right margin edge (3*VW wide region centered at 0 → right = 1.5*VW)
    const card: Rect = { x: 1.5 * VW - 10, y: 0, w: 100, h: 100 };
    expect(isCardVisible(card, vp, VW, VH, 1)).toBe(true);
  });

  it("hides a card more than 1 viewport off-screen", () => {
    const card: Rect = { x: 2 * VW, y: 0, w: 100, h: 100 };
    expect(isCardVisible(card, vp, VW, VH, 1)).toBe(false);
  });

  it("a wider margin keeps a distant card alive", () => {
    const card: Rect = { x: 2 * VW, y: 0, w: 100, h: 100 };
    expect(isCardVisible(card, vp, VW, VH, 3)).toBe(true);
  });
});
