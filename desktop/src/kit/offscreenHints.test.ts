// Tests for the overlay-level offscreen-hint logic (priority, fly-target
// selection, label, per-edge stacking). The edge geometry it builds on is tested
// in boardWayfinding.test.ts; these are net-new (the Swift overlay layer was
// untested).

import { describe, it, expect } from "vitest";
import { hintPriority, selectFlyTarget, pillLabel, stackPills, type OffscreenHint } from "./offscreenHints";
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
});
