// Port of TarmacKitTests/BoardWayfindingTests.swift — Phase 4 wayfinding math
// (crib §6–7): fit-to-cards bbox, the world↔minimap mapping, the offscreen-hint
// edge geometry, and ⌘T cascade placement. The React overlays are thin shells
// over this. Every Swift XCTest case is reproduced 1:1.

import { describe, it, expect } from 'vitest';
import {
  boundingBox,
  fit,
  minimapMapping,
  arrow,
  isOffscreen,
  hintPlacement,
  cascadeOrigin,
} from './boardWayfinding';
import type { Edge } from './boardWayfinding';

describe('BoardWayfinding', () => {
  // MARK: - Bounding box

  it('unions all rects', () => {
    const box = boundingBox([
      { x: 0, y: 0, w: 100, h: 100 },
      { x: 200, y: 50, w: 100, h: 100 },
    ]);
    expect(box).toEqual({ x: 0, y: 0, w: 300, h: 150 });
  });

  it('bounding box of empty is null', () => {
    expect(boundingBox([])).toBeNull();
  });

  // MARK: - Fit to cards

  // Fit centers on the bbox and picks the largest zoom that keeps the box inside
  // the usable (margin-reduced) viewport. Box 400×200, viewport 800×600, 10%
  // margin → usable 640×480; zx=1.6, zy=2.4 → zoom = 1.6, clamped under max 3.
  it('fit centers and scales to the limiting axis', () => {
    const f = fit(
      [{ x: 100, y: 100, w: 400, h: 200 }],
      { w: 800, h: 600 },
      0.1,
      0.1,
      3.0,
    );
    expect(f).not.toBeNull();
    expect(f!.center.x).toBeCloseTo(300, 9); // 100 + 400/2
    expect(f!.center.y).toBeCloseTo(200, 9); // 100 + 200/2
    expect(f!.zoom).toBeCloseTo(1.6, 9);
  });

  // A box larger than the viewport zooms OUT (zoom < 1) to fit, still clamped to
  // minZoom. Box 4000×4000, viewport 800×600, 10% margin → usable 640×480; min
  // ratio = 480/4000 = 0.12.
  it('fit zooms out for oversize box', () => {
    const f = fit(
      [{ x: 0, y: 0, w: 4000, h: 4000 }],
      { w: 800, h: 600 },
      0.1,
      0.1,
      3.0,
    );
    expect(f!.zoom).toBeCloseTo(0.12, 9);
  });

  it('fit clamps to max zoom', () => {
    // A tiny box would want a huge zoom; clamp at maxZoom.
    const f = fit(
      [{ x: 0, y: 0, w: 10, h: 10 }],
      { w: 800, h: 600 },
      0.1,
      0.1,
      3.0,
    );
    expect(f!.zoom).toBeCloseTo(3.0, 9);
  });

  it('fit clamps to min zoom', () => {
    const f = fit(
      [{ x: 0, y: 0, w: 100000, h: 100000 }],
      { w: 800, h: 600 },
      0.1,
      0.1,
      3.0,
    );
    expect(f!.zoom).toBeCloseTo(0.1, 9);
  });

  it('fit of no cards is null', () => {
    expect(
      fit([], { w: 800, h: 600 }, 0.1, 0.1, 3.0),
    ).toBeNull();
  });

  // Two cards: fit spans both, centered on their union.
  it('fit spans multiple cards', () => {
    const f = fit(
      [
        { x: 0, y: 0, w: 200, h: 200 },
        { x: 600, y: 0, w: 200, h: 200 },
      ],
      { w: 800, h: 600 },
      0.1,
      0.1,
      3.0,
    );
    // union = 0..800 x, 0..200 y → center 400,100.
    expect(f!.center.x).toBeCloseTo(400, 9);
    expect(f!.center.y).toBeCloseTo(100, 9);
    // usable 640×480; zx=640/800=0.8, zy=480/200=2.4 → 0.8.
    expect(f!.zoom).toBeCloseTo(0.8, 9);
  });

  // MARK: - Minimap mapping

  // A world box maps into the minimap with uniform scale + centering, and the
  // round-trip (world → minimap → world) is exact.
  it('minimap mapping round-trips', () => {
    const worldBox = { x: -100, y: -50, w: 1320, h: 880 };
    const mapping = minimapMapping(worldBox, { w: 132, h: 88 }, 6);
    const pts = [
      { x: -100, y: -50 },
      { x: 560, y: 390 },
      { x: 1220, y: 830 },
    ];
    for (const p of pts) {
      const mm = mapping.toMinimap(p);
      const back = mapping.toWorld(mm);
      expect(back.x).toBeCloseTo(p.x, 6);
      expect(back.y).toBeCloseTo(p.y, 6);
    }
  });

  // The scale is uniform (the smaller axis ratio) so the world aspect is
  // preserved. World box 1320×880 into 132×88 with pad 6 → avail 120×76;
  // sx=120/1320≈0.0909, sy=76/880≈0.0863 → uniform = 0.0863…
  it('minimap mapping uses uniform smaller scale', () => {
    const worldBox = { x: 0, y: 0, w: 1320, h: 880 };
    const mapping = minimapMapping(worldBox, { w: 132, h: 88 }, 6);
    const expected = 76.0 / 880.0;
    expect(mapping.scale).toBeCloseTo(expected, 9);
  });

  // The world box origin maps to the padded, centered offset (the box is
  // centered on the limiting axis).
  it('minimap mapping centers content', () => {
    const worldBox = { x: 0, y: 0, w: 880, h: 880 }; // square
    const mapping = minimapMapping(worldBox, { w: 132, h: 88 }, 6);
    // avail 120×76; square scaled by min(120/880, 76/880)=76/880 → 76 wide, 76
    // tall. Centered horizontally: x offset = 6 + (120-76)/2 = 28.
    const o = mapping.toMinimap({ x: 0, y: 0 });
    expect(o.x).toBeCloseTo(28, 9);
    expect(o.y).toBeCloseTo(6, 9);
  });

  it('minimap degenerate box has zero scale', () => {
    const mapping = minimapMapping({ x: 5, y: 5, w: 0, h: 0 }, { w: 132, h: 88 }, 6);
    expect(mapping.scale).toBe(0);
  });

  // MARK: - Offscreen-hint geometry

  it('hint placement inside view is null', () => {
    const p = hintPlacement(
      { x: 400, y: 300 },
      { x: 0, y: 0, w: 800, h: 600 },
      18,
    );
    expect(p).toBeNull();
  });

  it('hint placement picks the right edge', () => {
    const p = hintPlacement(
      { x: 1200, y: 300 },
      { x: 0, y: 0, w: 800, h: 600 },
      18,
    );
    expect(p?.edge).toBe('right');
    expect(p?.along).toBe(300); // y stays (within inset bounds)
  });

  it('hint placement picks top edge and clamps along', () => {
    // Card far above and slightly left: top overshoot dominates; the x is
    // clamped into [inset, width-inset].
    const p = hintPlacement(
      { x: -50, y: -500 },
      { x: 0, y: 0, w: 800, h: 600 },
      18,
    );
    expect(p?.edge).toBe('top');
    expect(p?.along).toBe(18); // clamped to minX + inset
  });

  it('hint placement left edge', () => {
    const p = hintPlacement(
      { x: -100, y: 250 },
      { x: 0, y: 0, w: 800, h: 600 },
      18,
    );
    expect(p?.edge).toBe('left');
    expect(p?.along).toBe(250);
  });

  it('hint placement bottom edge', () => {
    const p = hintPlacement(
      { x: 400, y: 900 },
      { x: 0, y: 0, w: 800, h: 600 },
      18,
    );
    expect(p?.edge).toBe('bottom');
    expect(p?.along).toBe(400);
  });

  it('edge arrows', () => {
    expect(arrow('left')).toBe('←');
    expect(arrow('right')).toBe('→');
    expect(arrow('top')).toBe('↑');
    expect(arrow('bottom')).toBe('↓');
  });

  it('is offscreen by center', () => {
    const vp = { x: 0, y: 0, w: 800, h: 600 };
    expect(isOffscreen({ x: 400, y: 300 }, vp)).toBe(false);
    expect(isOffscreen({ x: 900, y: 300 }, vp)).toBe(true);
  });

  // MARK: - Cascade placement (Phase 5b ⌘T)

  // With no collision, the cascade lands exactly one (dx, dy) down-right.
  it('cascade origin offsets from base', () => {
    const o = cascadeOrigin({ x: 80, y: 80 }, [], 43, 40);
    expect(o).toEqual({ x: 123, y: 120 });
  });

  // A card already sitting at the first cascade slot nudges the new card one
  // more step, so repeated ⌘T stair-steps instead of stacking.
  it('cascade origin nudges off existing card', () => {
    const base = { x: 80, y: 80 };
    // The prime card itself + a card already at the first cascade slot.
    const existing = [base, { x: 123, y: 120 }];
    const o = cascadeOrigin(base, existing, 43, 40);
    expect(o).toEqual({ x: 166, y: 160 });
  });

  // Three successive spawns (feeding each result back in) stair-step with no two
  // top-lefts coinciding.
  it('cascade origin three spawns are distinct', () => {
    const base = { x: 80, y: 80 };
    const existing = [base];
    const origins: Array<{ x: number; y: number }> = [];
    for (let i = 0; i < 3; i++) {
      const o = cascadeOrigin(base, existing, 43, 40);
      origins.push(o);
      existing.push(o);
    }
    expect(origins).toEqual([
      { x: 123, y: 120 },
      { x: 166, y: 160 },
      { x: 209, y: 200 },
    ]);
  });

  // Type-level exhaustiveness over Edge (not in the Swift suite, kept minimal):
  // every edge produces a non-empty arrow glyph.
  it('every edge has an arrow', () => {
    const edges: Edge[] = ['left', 'right', 'top', 'bottom'];
    for (const e of edges) expect(arrow(e).length).toBeGreaterThan(0);
  });
});
