// Pure card-resize geometry: given the frame at grab time, the dragged corner, and
// a WORLD-space drag delta, produce the new frame clamped to a minimum size. The
// top/left edges move the origin; the opposite edge stays pinned. Extracted from
// CardView.resized (Swift, untested AppKit) so the corner math + min clamp are
// unit-tested. Used by CardShell's resize handles; the engine's CSS-zoom
// transform scales the handles' bitmap automatically, as it does the card.

import type { WorldFrame } from "../board/model";

export type Corner = "tl" | "tr" | "bl" | "br";

export const MIN_CARD_W = 160;
export const MIN_CARD_H = 90;

export function resizeFrame(
  start: WorldFrame,
  corner: Corner,
  dxWorld: number,
  dyWorld: number,
  minW: number = MIN_CARD_W,
  minH: number = MIN_CARD_H,
): WorldFrame {
  let { x, y, w, h } = start;
  const movesLeft = corner === "tl" || corner === "bl";
  const movesTop = corner === "tl" || corner === "tr";

  if (movesLeft) {
    // Dragging the left edge: width changes inversely with dx; x follows so the
    // right edge stays pinned; clamp at minW (which pins x once minimal).
    const newW = Math.max(minW, w - dxWorld);
    x = x + (w - newW);
    w = newW;
  } else {
    w = Math.max(minW, w + dxWorld);
  }

  if (movesTop) {
    const newH = Math.max(minH, h - dyWorld);
    y = y + (h - newH);
    h = newH;
  } else {
    h = Math.max(minH, h + dyWorld);
  }

  return { x, y, w, h };
}
