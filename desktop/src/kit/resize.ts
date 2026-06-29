// Pure card-resize geometry: given the frame at grab time, the dragged handle, and
// a WORLD-space drag delta, produce the new frame clamped to a minimum size. Edge
// handles resize a single axis; corner handles resize both. The top/left edges move
// the origin; the opposite edge stays pinned. Min clamp is applied per active axis.
// Extracted from CardView.resized (Swift, untested AppKit) so the geometry + clamp
// are unit-tested. Used by CardShell's resize handles; the engine's CSS-zoom
// transform scales the handles' bitmap automatically, as it does the card.

import type { WorldFrame } from "../board/model";

export type Corner = "tl" | "tr" | "bl" | "br";
export type Edge   = "t"  | "b"  | "l"  | "r";
export type Handle = Corner | Edge;

export const MIN_CARD_W = 160;
export const MIN_CARD_H = 90;

export function resizeFrame(
  start: WorldFrame,
  handle: Handle,
  dxWorld: number,
  dyWorld: number,
  minW: number = MIN_CARD_W,
  minH: number = MIN_CARD_H,
): WorldFrame {
  let { x, y, w, h } = start;
  const movesLeft = handle === "tl" || handle === "bl" || handle === "l";
  const movesTop  = handle === "tl" || handle === "tr" || handle === "t";
  const activeX   = handle !== "t" && handle !== "b";
  const activeY   = handle !== "l" && handle !== "r";

  if (activeX) {
    if (movesLeft) {
      const newW = Math.max(minW, w - dxWorld);
      x = x + (w - newW);
      w = newW;
    } else {
      w = Math.max(minW, w + dxWorld);
    }
  }

  if (activeY) {
    if (movesTop) {
      const newH = Math.max(minH, h - dyWorld);
      y = y + (h - newH);
      h = newH;
    } else {
      h = Math.max(minH, h + dyWorld);
    }
  }

  return { x, y, w, h };
}
