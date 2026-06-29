// Port of TarmacKit/BoardWayfinding.swift — the pure wayfinding math for the v4
// board chrome (Phase 4 / crib §6–7): fit-to-cards, the world↔minimap mapping,
// the offscreen-hint edge geometry, and ⌘T cascade placement.
//
// All of it is view-independent (no AppKit), so it is a single, unit-tested
// source of truth that the React overlays (zoom control / minimap / offscreen
// hints) call into. Swift modelled this as an enum of static funcs + value
// structs; here the static funcs become exported functions, the structs become
// interfaces, and the one struct with behaviour (MinimapMapping) becomes a class.

import type { Point, Rect, Size } from './geom';
import { rectMaxX, rectMaxY, rectMidX, rectMidY, rectContains } from './geom';

// MARK: - Fit to cards (zoom control ⊡ fit; crib §6)

/** The result of fitting all cards into the viewport: a target zoom plus the
 * world-space center to point the viewport at. */
export interface Fit {
  zoom: number;
  center: Point;
}

/** Bounding box of a set of world rects (the card frames). Returns null for an
 * empty set. The union is exact (no inset) — callers add fit margin. */
export function boundingBox(rects: Rect[]): Rect | null {
  if (rects.length === 0) return null;
  let box = rects[0]!;
  for (let i = 1; i < rects.length; i++) {
    box = rectUnion(box, rects[i]!);
  }
  return box;
}

/** Fit-with-margin (crib §6): center the viewport on the cards' bounding box and
 * pick the largest zoom that keeps the box inside `viewportSize` with a `margin`
 * fraction of slack on every side (e.g. 0.1 = 10% padding). The zoom is clamped
 * to `[minZoom, maxZoom]`. Returns null when there are no cards (caller leaves
 * the viewport unchanged).
 *
 * A degenerate (zero width/height) box falls back to `maxZoom` so a single tiny
 * card doesn't blow the zoom up to infinity. */
export function fit(
  cards: Rect[],
  viewportSize: Size,
  margin: number,
  minZoom: number,
  maxZoom: number,
): Fit | null {
  const box = boundingBox(cards);
  if (box === null) return null;
  const center: Point = { x: rectMidX(box), y: rectMidY(box) };
  // Usable view extent after reserving `margin` on each side.
  const usableW = viewportSize.w * (1 - 2 * margin);
  const usableH = viewportSize.h * (1 - 2 * margin);
  if (!(usableW > 0) || !(usableH > 0)) {
    return { zoom: clamp(maxZoom, minZoom, maxZoom), center };
  }
  const zx = box.w > 0 ? usableW / box.w : maxZoom;
  const zy = box.h > 0 ? usableH / box.h : maxZoom;
  const zoom = clamp(Math.min(zx, zy), minZoom, maxZoom);
  return { zoom, center };
}

// MARK: - World ↔ minimap mapping (crib §6)

/** Maps the world bounding box (cards + the current viewport rect) into the
 * minimap's pixel box, preserving aspect ratio and centering, so the minimap
 * shows the same proportions as the board.
 *
 * `scale` is uniform (min of the two axis ratios) and `offset` recenters the
 * scaled content inside the minimap. `worldOrigin` is the world bbox origin. */
export class MinimapMapping {
  readonly worldOrigin: Point;
  readonly scale: number;
  readonly offset: Point;

  constructor(worldOrigin: Point, scale: number, offset: Point) {
    this.worldOrigin = worldOrigin;
    this.scale = scale;
    this.offset = offset;
  }

  /** world point → minimap point. */
  toMinimap(p: Point): Point {
    return {
      x: (p.x - this.worldOrigin.x) * this.scale + this.offset.x,
      y: (p.y - this.worldOrigin.y) * this.scale + this.offset.y,
    };
  }

  /** world rect → minimap rect. */
  toMinimapRect(r: Rect): Rect {
    const o = this.toMinimap({ x: r.x, y: r.y });
    return { x: o.x, y: o.y, w: r.w * this.scale, h: r.h * this.scale };
  }

  /** minimap point → world point (inverse; used for click-to-jump). */
  toWorld(p: Point): Point {
    if (this.scale === 0) return this.worldOrigin;
    return {
      x: (p.x - this.offset.x) / this.scale + this.worldOrigin.x,
      y: (p.y - this.offset.y) / this.scale + this.worldOrigin.y,
    };
  }
}

/** Builds the aspect-preserving, centered mapping from `worldBox` into a
 * `minimapSize` pixel box with `pad` pixels of inset on each side. A degenerate
 * world box (zero extent) maps to the minimap center at scale 0 — callers treat
 * that as "nothing meaningful to draw". */
export function minimapMapping(worldBox: Rect, minimapSize: Size, pad: number): MinimapMapping {
  const availW = Math.max(0, minimapSize.w - 2 * pad);
  const availH = Math.max(0, minimapSize.h - 2 * pad);
  const sx = worldBox.w > 0 ? availW / worldBox.w : 0;
  const sy = worldBox.h > 0 ? availH / worldBox.h : 0;
  // Uniform scale = the smaller ratio (so the box fits both axes).
  let scale: number;
  if (sx === 0 && sy === 0) {
    scale = 0;
  } else if (sx === 0) {
    scale = sy;
  } else if (sy === 0) {
    scale = sx;
  } else {
    scale = Math.min(sx, sy);
  }
  // Center the scaled content inside the available area.
  const scaledW = worldBox.w * scale;
  const scaledH = worldBox.h * scale;
  const offset: Point = {
    x: pad + (availW - scaledW) / 2,
    y: pad + (availH - scaledH) / 2,
  };
  return new MinimapMapping({ x: worldBox.x, y: worldBox.y }, scale, offset);
}

// MARK: - Offscreen hints (crib §6)

/** Which viewport edge a hint pins to, toward an offscreen card. */
export type Edge = 'left' | 'right' | 'top' | 'bottom';

/** The single-glyph direction arrow (crib §6: `→ ← ↑ ↓`). */
export function arrow(edge: Edge): string {
  switch (edge) {
    case 'left':
      return '←';
    case 'right':
      return '→';
    case 'top':
      return '↑';
    case 'bottom':
      return '↓';
  }
}

/** A computed hint placement: which edge to pin to, and the *position along that
 * edge* (the view-space coordinate of the card's center projected onto the edge,
 * clamped into the viewport so the pill stays on-screen). */
export interface HintPlacement {
  edge: Edge;
  /** For a left/right edge this is the view-space y; for top/bottom, the x. */
  along: number;
}

/** A card counts as offscreen when its *center* is outside the visible world
 * rect (so partially-visible cards near an edge still hint, matching the
 * design's "toward the card" intent). */
export function isOffscreen(cardCenterWorld: Point, viewportWorldRect: Rect): boolean {
  return !rectContains(viewportWorldRect, cardCenterWorld);
}

/** Places a hint pill for an offscreen card. Given the card center in VIEW space
 * and the visible view rect, pick the edge the card lies beyond (whichever axis
 * is most out of bounds) and the clamped position along it. `inset` keeps the
 * pill off the very corner. Returns null when the center is inside the view rect
 * (no hint needed). */
export function hintPlacement(
  cardCenterView: Point,
  viewRect: Rect,
  inset: number,
): HintPlacement | null {
  const c = cardCenterView;
  if (rectContains(viewRect, c)) return null;
  // Distance the center sits beyond each edge (positive = outside).
  const beyondLeft = viewRect.x - c.x;
  const beyondRight = c.x - rectMaxX(viewRect);
  const beyondTop = viewRect.y - c.y;
  const beyondBottom = c.y - rectMaxY(viewRect);

  // Pick the edge with the largest positive overshoot. Matches Swift's
  // `filter { > 0 }.max(by: { $0.1 < $1.1 })`: on a tie the FIRST-encountered
  // candidate wins (max(by:) only swaps on a strictly greater value), and edge
  // order is left, right, top, bottom.
  const candidates: Array<[Edge, number]> = [
    ['left', beyondLeft],
    ['right', beyondRight],
    ['top', beyondTop],
    ['bottom', beyondBottom],
  ];
  let best: [Edge, number] | null = null;
  for (const cand of candidates) {
    if (cand[1] > 0) {
      if (best === null || best[1] < cand[1]) best = cand;
    }
  }
  if (best === null) return null;
  const edge = best[0];

  const loY = viewRect.y + inset;
  const hiY = rectMaxY(viewRect) - inset;
  const loX = viewRect.x + inset;
  const hiX = rectMaxX(viewRect) - inset;
  switch (edge) {
    case 'left':
    case 'right':
      return { edge, along: clamp(c.y, loY, hiY) };
    case 'top':
    case 'bottom':
      return { edge, along: clamp(c.x, loX, hiX) };
  }
}

// MARK: - Cascade placement (Phase 5b: ⌘T new terminal card)

/** The top-left of a new card cascade-offset down-right from `base`, nudged by
 * `(dx, dy)` until it does not (near-)coincide with any existing card's top-left
 * (within `epsilon`) — so repeated ⌘T spawns stair-step instead of stacking on
 * one spot. `existing` are the existing cards' top-left world points. The nudge
 * is bounded so a pathological set can never loop forever. */
export function cascadeOrigin(
  base: Point,
  existing: Point[],
  dx: number,
  dy: number,
  epsilon: number = 8,
): Point {
  let x = base.x + dx;
  let y = base.y + dy;
  let steps = 0;
  while (existing.some((p) => Math.abs(p.x - x) < epsilon && Math.abs(p.y - y) < epsilon)) {
    x += dx;
    y += dy;
    steps += 1;
    if (steps > 1024) break;
  }
  return { x, y };
}

// MARK: -

/** Union of two rects (matches CGRect.union): the smallest rect containing both. */
function rectUnion(a: Rect, b: Rect): Rect {
  const minX = Math.min(a.x, b.x);
  const minY = Math.min(a.y, b.y);
  const maxX = Math.max(rectMaxX(a), rectMaxX(b));
  const maxY = Math.max(rectMaxY(a), rectMaxY(b));
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}
