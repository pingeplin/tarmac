// Tests for the overlay-level offscreen-hint logic (priority, fly-target
// selection, label, per-edge stacking). The edge geometry it builds on is tested
// in boardWayfinding.test.ts; these are net-new (the Swift overlay layer was
// untested).

import { describe, it, expect } from "vitest";
import { hintPriority, selectFlyTarget, pillLabel, stackPills, type OffscreenHint } from "./offscreenHints";
import { rectsIntersect } from "./placement";
import type { Rect, Size } from "./geom";

const hint = (
  cardId: string,
  centerView: { x: number; y: number },
  signal: "bell" | "live",
  z: number,
): OffscreenHint => ({ cardId, centerView, signal, label: cardId, z });

describe("hintPriority", () => {
  it("bell always outranks live; z breaks ties within a class", () => {
    expect(hintPriority("bell", 5)).toBe(1005);
    expect(hintPriority("live", 5)).toBe(5);
    expect(hintPriority("bell", 0)).toBeGreaterThan(hintPriority("live", 999));
  });
});

describe("selectFlyTarget", () => {
  it("returns null for no hints", () => {
    expect(selectFlyTarget([])).toBeNull();
  });
  it("a bell with lower z beats a higher-z live", () => {
    const t = selectFlyTarget([hint("live", { x: 0, y: 0 }, "live", 100), hint("bell", { x: 0, y: 0 }, "bell", 1)]);
    expect(t).toBe("bell");
  });
  it("among two bells the higher z wins", () => {
    const t = selectFlyTarget([hint("lo", { x: 0, y: 0 }, "bell", 1), hint("hi", { x: 0, y: 0 }, "bell", 9)]);
    expect(t).toBe("hi");
  });
  it("equal priority returns the FIRST in array order", () => {
    const t = selectFlyTarget([hint("first", { x: 0, y: 0 }, "live", 5), hint("second", { x: 0, y: 0 }, "live", 5)]);
    expect(t).toBe("first");
  });
});

describe("pillLabel", () => {
  it("joins name and time with a middle dot for bell; name only for live", () => {
    expect(pillLabel("bell", "notes.md", "14:32")).toBe("notes.md · 14:32");
    expect(pillLabel("live", "agent", "14:32")).toBe("agent");
  });
});

describe("stackPills", () => {
  const view: Rect = { x: 0, y: 0, w: 1000, h: 800 };
  const size: Size = { w: 80, h: 24 };
  const opts = { edgeInset: 18, edgeMargin: 10, stackGap: 8, pillSize: () => size };

  it("returns [] for empty input", () => {
    expect(stackPills([], view, opts)).toEqual([]);
  });

  it("skips hints whose center is inside the view", () => {
    expect(stackPills([hint("in", { x: 500, y: 400 }, "live", 0)], view, opts)).toEqual([]);
  });

  it("places a right-edge hint flush right, clamped vertically", () => {
    const [p] = stackPills([hint("r", { x: 2000, y: 400 }, "bell", 0)], view, opts);
    expect(p!.edge).toBe("right");
    expect(p!.arrow).toBe("→");
    expect(p!.left).toBe(1000 - 80 - 10); // maxX - w - margin
    expect(p!.top).toBe(400 - 12); // clamp(centerY - h/2, ...)
  });

  it("nudges a second overlapping right-edge pill down by >= stackGap", () => {
    const pills = stackPills(
      [hint("a", { x: 2000, y: 400 }, "bell", 0), hint("b", { x: 2000, y: 405 }, "bell", 0)],
      view,
      opts,
    );
    const a = pills.find((p) => p.cardId === "a")!;
    const b = pills.find((p) => p.cardId === "b")!;
    expect(b.top).toBeGreaterThanOrEqual(a.top + size.h + 8);
  });

  it("clamps a pill that would exceed maxY", () => {
    const [p] = stackPills([hint("low", { x: 2000, y: 5000 }, "bell", 0)], view, opts);
    expect(p!.top).toBe(800 - 24 - 10); // maxY - h - margin
  });

  it("nudges a pill clear of an unrelated obstacle it would otherwise land on", () => {
    // Naive placement (no obstacles) would land this pill's rect at
    // {left: 920, top: 388, w: 80, h: 24}; the obstacle overlaps that band.
    const obstacle: Rect = { x: 900, y: 380, w: 100, h: 40 };
    const [p] = stackPills([hint("r", { x: 2000, y: 400 }, "bell", 0)], view, { ...opts, obstacles: [obstacle] });
    const rect: Rect = { x: p!.left, y: p!.top, w: size.w, h: size.h };
    expect(rectsIntersect(rect, obstacle)).toBe(false);
    expect(p!.top).toBeGreaterThan(388);
  });

  it("lands in the gap between two obstacles rather than overshooting the second", () => {
    const obstacleA: Rect = { x: 900, y: 180, w: 100, h: 40 };
    const obstacleB: Rect = { x: 900, y: 260, w: 100, h: 40 };
    const [p] = stackPills([hint("b", { x: 2000, y: 200 }, "bell", 0)], view, {
      ...opts,
      obstacles: [obstacleA, obstacleB],
    });
    expect(p!.top).toBe(228); // obstacleA.y + obstacleA.h + stackGap
    const rect = { x: 910, y: p!.top, w: size.w, h: size.h };
    expect(rectsIntersect(rect, obstacleA)).toBe(false);
    expect(rectsIntersect(rect, obstacleB)).toBe(false);
  });

  it("nudges away from an obstacle rect even when it coincides with the hinted card's own sliver", () => {
    // obstacles carry no cardId, so stackPills has no way to exempt "own card" —
    // an obstacle placed exactly where the hinted card's own rect would be still
    // pushes the pill clear of it.
    const ownCardObstacle: Rect = { x: 900, y: 380, w: 100, h: 40 };
    const [p] = stackPills([hint("r", { x: 2000, y: 400 }, "bell", 0)], view, {
      ...opts,
      obstacles: [ownCardObstacle],
    });
    const rect = { x: p!.left, y: p!.top, w: size.w, h: size.h };
    expect(rectsIntersect(rect, ownCardObstacle)).toBe(false);
  });

  it("never suppresses a pill even when the obstacle band is fully saturated", () => {
    const saturating: Rect = { x: 900, y: -1000, w: 100, h: 3000 };
    const pills = stackPills([hint("r", { x: 2000, y: 400 }, "bell", 0)], view, {
      ...opts,
      obstacles: [saturating],
    });
    expect(pills.length).toBe(1);
    const [p] = pills;
    expect(p!.top).toBeGreaterThanOrEqual(10); // clamped within [posLo, posHi]
    expect(p!.top).toBeLessThanOrEqual(800 - 24 - 10);
  });

  it("never stacks same-edge pills on top of each other when an obstacle saturates the band", () => {
    // A maximized on-screen card spans nearly the whole right band; four
    // offscreen bells land close together on the same edge. Each pill must
    // still avoid every other pill, even though avoiding the obstacle too is
    // best-effort (S4) and some may still overlap it.
    const obstacle: Rect = { x: 900, y: 300, w: 100, h: 460 };
    const pills = stackPills(
      [
        hint("a", { x: 2000, y: 400 }, "bell", 0),
        hint("b", { x: 2000, y: 412 }, "bell", 0),
        hint("c", { x: 2000, y: 424 }, "bell", 0),
        hint("d", { x: 2000, y: 436 }, "bell", 0),
      ],
      view,
      { ...opts, obstacles: [obstacle] },
    );
    expect(pills.length).toBe(4);
    const rects = pills.map((p) => ({ x: p.left, y: p.top, w: size.w, h: size.h }));
    for (let i = 0; i < rects.length; i++) {
      for (let j = i + 1; j < rects.length; j++) {
        expect(rectsIntersect(rects[i]!, rects[j]!)).toBe(false);
      }
      // The obstacle avoidance nudge must never push a pill outside the viewport
      // margin bounds even when it also has to clear a same-edge sibling —
      // .offscreen-hints clips at the viewport edge, so an out-of-bounds pill
      // would render nowhere at all (worse than the overlap being avoided).
      expect(rects[i]!.y).toBeGreaterThanOrEqual(10);
      expect(rects[i]!.y).toBeLessThanOrEqual(800 - 24 - 10);
    }
  });

  it("stays within viewport bounds when an obstacle forces a later same-edge sibling to jump a gap", () => {
    const obstacle: Rect = { x: 900, y: 492, w: 100, h: 416 }; // padded interval ~[484, 916]
    const pills = stackPills(
      [hint("a", { x: 2000, y: 300 }, "bell", 0), hint("b", { x: 2000, y: 550 }, "bell", 0)],
      view,
      { ...opts, obstacles: [obstacle] },
    );
    for (const p of pills) {
      expect(p.top).toBeGreaterThanOrEqual(10);
      expect(p.top).toBeLessThanOrEqual(800 - 24 - 10);
    }
    const rects = pills.map((p) => ({ x: p.left, y: p.top, w: size.w, h: size.h }));
    expect(rectsIntersect(rects[0]!, rects[1]!)).toBe(false);
  });

  it("composes obstacle avoidance with sibling stackGap in one pass", () => {
    const obstacle: Rect = { x: 900, y: 118, w: 100, h: 22 };
    const pills = stackPills(
      [hint("a", { x: 2000, y: 100 }, "bell", 0), hint("b", { x: 2000, y: 105 }, "bell", 0)],
      view,
      { ...opts, obstacles: [obstacle] },
    );
    const a = pills.find((p) => p.cardId === "a")!;
    const b = pills.find((p) => p.cardId === "b")!;
    expect(b.top).toBeGreaterThanOrEqual(a.top + size.h + 8);
    const bRect = { x: b.left, y: b.top, w: size.w, h: size.h };
    expect(rectsIntersect(bRect, obstacle)).toBe(false);
  });
});
