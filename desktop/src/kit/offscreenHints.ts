// Overlay-level offscreen-hint logic: priority, the single Return-fly target, the
// pill label, and the per-edge greedy stacking layout. The edge GEOMETRY
// (isOffscreen / hintPlacement / arrow) is already in boardWayfinding.ts; this
// adds the parts that lived in the untested AppKit layer (OffscreenHints.swift
// layout() + AppController.offscreenHints()), so this is their first unit
// coverage. Pure + time-free; the view supplies measured pill sizes + HH:MM.

import { arrow, hintPlacement, type Edge, type HintPlacement } from "./boardWayfinding";
import type { Point, Rect, Size } from "./geom";

export type Signal = "bell" | "live";

/** One signalling offscreen card, in VIEW (overlay-local) coordinates. */
export interface OffscreenHint {
  cardId: string;
  centerView: Point;
  signal: Signal;
  label: string;
  /** Stacking order; higher = more recently fronted. Feeds priority. */
  z: number;
}

/** A laid-out pill: which edge, its arrow glyph, and the overlay-local top-left. */
export interface PlacedPill {
  cardId: string;
  signal: Signal;
  label: string;
  edge: Edge;
  arrow: string;
  left: number;
  top: number;
}

/** Bell always outranks live; within a class the most-recently-fronted (higher z)
 * wins. priority = (bell ? 1000 : 0) + z (AppController offscreen target rule). */
export function hintPriority(signal: Signal, z: number): number {
  return (signal === "bell" ? 1000 : 0) + z;
}

/** The single ⏎-fly target: the highest-priority hint's cardId, or null when
 * empty. First-wins on ties (array order), matching Swift's strictly-greater
 * swap — so callers must iterate cards in a stable order for determinism. */
export function selectFlyTarget(hints: OffscreenHint[]): string | null {
  let best: OffscreenHint | null = null;
  let bestP = -Infinity;
  for (const h of hints) {
    const p = hintPriority(h.signal, h.z);
    if (best === null || p > bestP) {
      best = h;
      bestP = p;
    }
  }
  return best ? best.cardId : null;
}

/** bell => `${name} · ${hhmm}` (middle dot U+00B7), live => name. */
export function pillLabel(signal: Signal, name: string, hhmm: string): string {
  return signal === "bell" ? `${name} · ${hhmm}` : name;
}

export interface StackOpts {
  /** Passed to hintPlacement as the edge inset (OffscreenHints.edgeInset = 18). */
  edgeInset: number;
  /** Gap kept between a pill and the viewport edge (edgeMargin = 10). */
  edgeMargin: number;
  /** Minimum gap between two stacked pills on the same edge (stackGap = 8). */
  stackGap: number;
  /** Measured pill size (the view knows the mono text metrics). */
  pillSize: (h: OffscreenHint) => Size;
}

/** Project each offscreen hint to an edge, group by edge, sort along the edge,
 * greedily nudge stacked pills apart by stackGap, clamp inside the view minus
 * margins, and round. Hints whose center is inside the view are skipped (their
 * hintPlacement is null). Mirrors OffscreenHints.swift rebuild()+layout(). */
export function stackPills(hints: OffscreenHint[], viewRect: Rect, opts: StackOpts): PlacedPill[] {
  const { edgeInset, edgeMargin, stackGap, pillSize } = opts;

  const projected: Array<{ h: OffscreenHint; p: HintPlacement; size: Size }> = [];
  for (const h of hints) {
    const p = hintPlacement(h.centerView, viewRect, edgeInset);
    if (p) projected.push({ h, p, size: pillSize(h) });
  }

  const minX = viewRect.x;
  const minY = viewRect.y;
  const maxX = viewRect.x + viewRect.w;
  const maxY = viewRect.y + viewRect.h;

  const out: PlacedPill[] = [];
  const edges: Edge[] = ["left", "right", "top", "bottom"];
  for (const edge of edges) {
    const group = projected.filter((x) => x.p.edge === edge);
    group.sort((a, b) => a.p.along - b.p.along);
    let lastEnd = -Infinity; // bottom (or right) edge of the previously placed pill
    for (const { h, p, size } of group) {
      let left: number;
      let top: number;
      if (edge === "left" || edge === "right") {
        let y = clamp(p.along - size.h / 2, minY + edgeMargin, maxY - size.h - edgeMargin);
        if (y < lastEnd + stackGap) y = lastEnd + stackGap; // nudge down past the last pill
        lastEnd = y + size.h;
        top = y;
        left = edge === "left" ? minX + edgeMargin : maxX - size.w - edgeMargin;
      } else {
        let x = clamp(p.along - size.w / 2, minX + edgeMargin, maxX - size.w - edgeMargin);
        if (x < lastEnd + stackGap) x = lastEnd + stackGap; // nudge right past the last pill
        lastEnd = x + size.w;
        top = edge === "top" ? minY + edgeMargin : maxY - size.h - edgeMargin;
        left = x;
      }
      out.push({
        cardId: h.cardId,
        signal: h.signal,
        label: h.label,
        edge,
        arrow: arrow(edge),
        left: Math.round(left),
        top: Math.round(top),
      });
    }
  }
  return out;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}
