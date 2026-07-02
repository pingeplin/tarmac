// Overlay-level offscreen-hint logic: priority, the single Return-fly target, the
// pill label, and the per-edge greedy stacking layout. The edge GEOMETRY
// (isOffscreen / hintPlacement / arrow) is already in boardWayfinding.ts; this
// adds the parts that lived in the untested AppKit layer (OffscreenHints.swift
// layout() + AppController.offscreenHints()), so this is their first unit
// coverage. Pure + time-free; the view supplies measured pill sizes + HH:MM.

import { arrow, hintPlacement, type Edge, type HintPlacement } from "./boardWayfinding";
import type { Point, Rect, Size } from "./geom";
import { rectsIntersect } from "./placement";

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
  /** Every currently-visible card's view-space rect, treated as a uniform
   * obstacle set (no card identity) that pills are nudged clear of. */
  obstacles?: Rect[];
}

/** Project each offscreen hint to an edge, group by edge, sort along the edge,
 * greedily nudge stacked pills apart by stackGap, clamp inside the view minus
 * margins, and round. Hints whose center is inside the view are skipped (their
 * hintPlacement is null). Mirrors OffscreenHints.swift rebuild()+layout(). */
export function stackPills(hints: OffscreenHint[], viewRect: Rect, opts: StackOpts): PlacedPill[] {
  const { edgeInset, edgeMargin, stackGap, pillSize, obstacles = [] } = opts;

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
    let lastEnd = -Infinity; // far edge, along-axis, of the previously placed pill
    for (const { h, p, size } of group) {
      const vertical = edge === "left" || edge === "right";
      const len = vertical ? size.h : size.w;
      const posLo = (vertical ? minY : minX) + edgeMargin;
      const posHi = (vertical ? maxY : maxX) - len - edgeMargin;
      const crossPos =
        edge === "left"
          ? minX + edgeMargin
          : edge === "right"
            ? maxX - size.w - edgeMargin
            : edge === "top"
              ? minY + edgeMargin
              : maxY - size.h - edgeMargin;
      const bandRect: Rect = vertical
        ? { x: crossPos, y: minY, w: size.w, h: maxY - minY }
        : { x: minX, y: crossPos, w: maxX - minX, h: size.h };
      const obstacleIntervals: Interval[] = obstacles
        .filter((o) => rectsIntersect(bandRect, o))
        .map((o) =>
          vertical
            ? { lo: o.y - stackGap, hi: o.y + o.h + stackGap }
            : { lo: o.x - stackGap, hi: o.x + o.w + stackGap },
        );
      const siblingFloor = lastEnd + stackGap;
      const desired = clamp(p.along - len / 2, posLo, posHi);
      const pos = resolveAlongPos(desired, len, obstacleIntervals, siblingFloor, posLo, posHi);
      lastEnd = pos + len;
      out.push({
        cardId: h.cardId,
        signal: h.signal,
        label: h.label,
        edge,
        arrow: arrow(edge),
        left: Math.round(vertical ? crossPos : pos),
        top: Math.round(vertical ? pos : crossPos),
      });
    }
  }
  return out;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, v));
}

interface Interval {
  lo: number;
  hi: number;
}

function mergeIntervals(intervals: Interval[]): Interval[] {
  const sorted = [...intervals].sort((a, b) => a.lo - b.lo);
  const out: Interval[] = [];
  for (const iv of sorted) {
    const last = out[out.length - 1];
    if (last && iv.lo <= last.hi) last.hi = Math.max(last.hi, iv.hi);
    else out.push({ ...iv });
  }
  return out;
}

/** Find a position for a `len`-long pill that never overlaps the previous
 * sibling on this edge (`siblingFloor`) and, best-effort, avoids `obstacles`
 * too — while always staying inside `[posLo, posHi]` (the viewport margin
 * bounds), since `.offscreen-hints` clips at the viewport edge: an unclamped
 * pill would simply vanish, which is worse than residual overlap.
 *
 * The one exception is pure over-saturation — so many same-edge pills that
 * `siblingFloor` alone has already pushed past `posHi`, with or without
 * obstacles in play. That has no valid answer in-bounds; push forward past
 * whatever's in the way and let it overflow, exactly like the pre-fix scalar
 * nudge (unbounded stacking there is pre-existing, accepted behavior).
 *
 * Otherwise, search `[max(posLo, siblingFloor), posHi]` for the free gap (the
 * window minus the obstacle intervals that fall in it) closest to `desired`;
 * ties favor the later/forward gap, matching the sibling nudge's own
 * forward-only bias. If obstacles saturate the entire window, fall back to
 * the window-clamped `desired` (residual obstacle overlap, but in-bounds and
 * never overlapping the sibling). A pill is always returned, never
 * suppressed. */
function resolveAlongPos(
  desired: number,
  len: number,
  obstacles: Interval[],
  siblingFloor: number,
  posLo: number,
  posHi: number,
): number {
  const lo = Math.max(posLo, siblingFloor);
  if (lo > posHi) {
    let pos = Math.max(desired, siblingFloor);
    for (const o of mergeIntervals(obstacles)) {
      if (pos < o.hi && pos + len > o.lo) pos = o.hi;
    }
    return pos;
  }

  const windowed = mergeIntervals(obstacles)
    .map((o) => ({ lo: Math.max(o.lo, lo), hi: Math.min(o.hi, posHi) }))
    .filter((o) => o.hi > o.lo);
  const clampedDesired = clamp(desired, lo, posHi);
  if (!windowed.some((o) => clampedDesired < o.hi && clampedDesired + len > o.lo)) return clampedDesired;

  const gaps: Interval[] = [];
  let cursor = lo;
  for (const o of windowed) {
    if (o.lo > cursor) gaps.push({ lo: cursor, hi: o.lo });
    cursor = Math.max(cursor, o.hi);
  }
  if (posHi > cursor) gaps.push({ lo: cursor, hi: posHi });

  let best: number | null = null;
  let bestDist = Infinity;
  for (const g of gaps) {
    if (g.hi - g.lo < len) continue;
    const candidate = clamp(clampedDesired, g.lo, g.hi - len);
    const dist = Math.abs(candidate - clampedDesired);
    if (dist <= bestDist) {
      bestDist = dist;
      best = candidate;
    }
  }
  return best ?? clampedDesired;
}
