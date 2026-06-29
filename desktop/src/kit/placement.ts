// Port of the Swift app's doc-card placement (AppController.firstFreeSlot +
// the `Place` constants): where a `tarmac open` doc lands on the board. A fresh
// doc is placed beside its owning terminal in a first-free-slot grid search with
// an 8px collision inset, so multiple docs from one terminal stack neatly instead
// of landing on top of each other. The M1 migration path (a persisted doc tile
// with no geometry) falls back to a deterministic 2-column scatter.
//
// World space is top-down/flipped (larger y = lower), matching geom.ts + the board.

import type { Rect } from "./geom";

/** Layout constants (Swift `Place`): the boot terminal frame + doc size/gaps. */
export const Place = {
  termFrame: { x: 80, y: 80, w: 470, h: 330 } as Rect,
  docW: 392,
  docH: 310,
  gapX: 86,
  gapY: 40,
  /** ⌘T terminal cascade nudge (consumed via boardWayfinding.cascadeOrigin). */
  cascadeDx: 43,
  cascadeDy: 40,
  /** First-free-slot scan extent (Swift scans a 64×64 grid before falling back). */
  scanRows: 64,
  scanCols: 64,
  /** Collision safety inset: a candidate must clear every existing card by 8px. */
  collisionInset: 8,
  /** Default 2-column count for the M1 scatter fallback. */
  docColumns: 2,
} as const;

/** Half-open rect overlap (matches CGRect.intersects: shared edges do NOT count). */
export function rectsIntersect(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

/** Grow a rect by `d` on every side (CGRect.insetBy(-d,-d)). */
function grow(r: Rect, d: number): Rect {
  return { x: r.x - d, y: r.y - d, w: r.w + 2 * d, h: r.h + 2 * d };
}

/**
 * The world frame for a fresh doc card owned by `owner`. Scans a grid anchored
 * to the right of the owner terminal (startX = owner right + gapX, startY =
 * owner top), row-major, returning the first `docW×docH` slot that clears every
 * `existing` card by `collisionInset`. If the whole grid is occupied it stacks at
 * the anchor (the Swift fallback) — geometry is still valid, just overlapping.
 */
export function firstFreeSlot(owner: Rect, existing: Rect[]): Rect {
  const startX = owner.x + owner.w + Place.gapX;
  const startY = owner.y;
  const grown = existing.map((e) => grow(e, Place.collisionInset));
  for (let row = 0; row < Place.scanRows; row++) {
    for (let col = 0; col < Place.scanCols; col++) {
      const candidate: Rect = {
        x: startX + col * (Place.docW + Place.gapX),
        y: startY + row * (Place.docH + Place.gapY),
        w: Place.docW,
        h: Place.docH,
      };
      if (!grown.some((e) => rectsIntersect(candidate, e))) return candidate;
    }
  }
  return { x: startX, y: startY, w: Place.docW, h: Place.docH };
}

/**
 * Deterministic 2-column scatter for an M1 doc tile that carried no geometry
 * (Swift `scatterFrame(docSlot)`): fills right-of-terminal in `docColumns`
 * columns, top to bottom. `slot` is the doc's 0-based offset among scattered docs.
 */
export function scatterFrame(slot: number, owner: Rect = Place.termFrame): Rect {
  const col = slot % Place.docColumns;
  const row = Math.floor(slot / Place.docColumns);
  return {
    x: owner.x + owner.w + Place.gapX + col * (Place.docW + Place.gapX),
    y: owner.y + row * (Place.docH + Place.gapY),
    w: Place.docW,
    h: Place.docH,
  };
}
