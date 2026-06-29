import { describe, it, expect } from "vitest";
import { worldToView, viewToWorld } from "./boardTransform";
import type { Point } from "./geom";

// Port of the World↔view transform cases from BoardPersistenceTests.swift
// (crib §5). The tile/wire persistence round-trips in that Swift file are
// covered by the Rust protocol crate, not here, so they are intentionally
// skipped — only the coordinate-transform behaviour lives in this module.
describe("BoardTransform", () => {
  // `view = (world − center)·zoom + viewportCenter`, inverted exactly.
  it("world↔view round trip", () => {
    const center: Point = { x: 640, y: 360 };
    const viewportCenter: Point = { x: 550, y: 350 };
    for (const zoom of [0.36, 0.5, 0.82, 1.0, 2.5]) {
      for (const p of [
        { x: 0, y: 0 },
        { x: 123.5, y: -42 },
        { x: 1280, y: 720 },
      ] as Point[]) {
        const v = worldToView(p, zoom, center, viewportCenter);
        const back = viewToWorld(v, zoom, center, viewportCenter);
        expect(back.x).toBeCloseTo(p.x, 6);
        expect(back.y).toBeCloseTo(p.y, 6);
      }
    }
  });

  // The world center always projects to the view-space viewport center,
  // independent of zoom (the pivot of the transform).
  it("center maps to viewportCenter", () => {
    const center: Point = { x: 100, y: 200 };
    const viewportCenter: Point = { x: 550, y: 350 };
    for (const zoom of [0.36, 1.0, 3.0]) {
      const v = worldToView(center, zoom, center, viewportCenter);
      expect(v.x).toBeCloseTo(viewportCenter.x, 9);
      expect(v.y).toBeCloseTo(viewportCenter.y, 9);
    }
  });

  // At zoom 1 with center == viewportCenter, world and view coincide (identity).
  it("identity at unit zoom, aligned center", () => {
    const c: Point = { x: 300, y: 300 };
    const p: Point = { x: 412, y: 88 };
    const v = worldToView(p, 1, c, c);
    expect(v).toEqual(p);
  });

  // One world unit maps to `zoom` view units (scale check).
  it("zoom scales world deltas", () => {
    const center: Point = { x: 0, y: 0 };
    const viewportCenter: Point = { x: 400, y: 300 };
    const zoom = 0.5;
    const a = worldToView({ x: 0, y: 0 }, zoom, center, viewportCenter);
    const b = worldToView({ x: 100, y: 100 }, zoom, center, viewportCenter);
    expect(b.x - a.x).toBeCloseTo(50, 9);
    expect(b.y - a.y).toBeCloseTo(50, 9);
  });
});
