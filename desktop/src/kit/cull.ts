// Viewport culling (perf fix #5, ported from BoardView.cull): a card more than
// one full viewport off-screen is hidden so it stops compositing — but the node
// is kept ALIVE (the Swift app uses isHidden, never removeFromSuperview, so a
// terminal keeps receiving PTY output and a doc keeps its scroll). Here the
// BoardEngine toggles `visibility:hidden` imperatively on the pan/zoom hot path;
// this module is just the pure predicate (so it is unit-tested, per the perf
// doc's testability note), independent of the DOM.
//
// The visible region is the viewport rect in WORLD coordinates, grown by
// `margin` full viewports on every side (Swift: bounds.insetBy(-w, -h), margin=1).

import type { Rect } from "./geom";
import { rectsIntersect } from "./placement";

/** The board viewport (zoom + world-space center); mirrors BoardEngine.Viewport
 * but declared here so the kit stays free of any board/DOM dependency. */
export interface Viewport {
  zoom: number;
  cx: number;
  cy: number;
}

/** Default cull margin in viewports per side (Swift inset = 1 full viewport). */
export const CULL_MARGIN_VIEWPORTS = 1;

/**
 * The world-space rectangle that is on-screen (the `viewSize` pixel viewport
 * un-projected at `vp.zoom` around `vp` center), grown by `marginViewports` full
 * viewports on each side. A card intersecting this rect stays visible.
 */
export function visibleWorldRect(
  vp: Viewport,
  viewWidthPx: number,
  viewHeightPx: number,
  marginViewports: number = CULL_MARGIN_VIEWPORTS,
): Rect {
  const visW = viewWidthPx / vp.zoom; // viewport width in world units
  const visH = viewHeightPx / vp.zoom;
  const halfW = visW / 2 + marginViewports * visW;
  const halfH = visH / 2 + marginViewports * visH;
  return {
    x: vp.cx - halfW,
    y: vp.cy - halfH,
    w: 2 * halfW,
    h: 2 * halfH,
  };
}

/**
 * Whether a card at world `frame` should be rendered (within the grown viewport).
 * Cards that fail this are hidden via `visibility:hidden` but kept alive.
 */
export function isCardVisible(
  frame: Rect,
  vp: Viewport,
  viewWidthPx: number,
  viewHeightPx: number,
  marginViewports: number = CULL_MARGIN_VIEWPORTS,
): boolean {
  return rectsIntersect(frame, visibleWorldRect(vp, viewWidthPx, viewHeightPx, marginViewports));
}
