// Pure module: terminal-card zoom layout — the outer wrapper is translate-only
// (identical formula to docWrapperBox); the inner box is zoom-free (var(--card-w/h))
// with a single scale(var(--zoom)) so the host never resizes on zoom → no fit()/PTY resize.

/** Real-px outer wrapper for a terminal card in .card-layer.
 *  String-for-string identical to docWrapperBox() — asserted by S1. */
export function termWrapperBox(): {
  width: string;
  height: string;
  transform: string;
  transformOrigin: string;
} {
  return {
    width: "calc(var(--card-w) * var(--zoom))",
    height: "calc(var(--card-h) * var(--zoom))",
    transform:
      "translate(round(calc(var(--world-tx) + var(--card-x) * var(--zoom)),var(--device-px)),round(calc(var(--world-ty) + var(--card-y) * var(--zoom)),var(--device-px)))",
    transformOrigin: "0 0",
  };
}

/** Per-card CSS custom properties — same shape as docCardVars(). */
export function termCardVars({ x, y, w, h }: { x: number; y: number; w: number; h: number }): {
  "--card-x": string;
  "--card-y": string;
  "--card-w": string;
  "--card-h": string;
} {
  return {
    "--card-x": `${x}px`,
    "--card-y": `${y}px`,
    "--card-w": `${w}px`,
    "--card-h": `${h}px`,
  };
}

/** Card-header height in WORLD px. Mirrors the 30px in card.css; the chrome
 *  renders it at 30px×zoom real px, so the body owns card-h minus this. */
export const CARD_HEADER_H_PX = 30;

/** Zoom-free host box, living INSIDE the card body. Width/height are zoom-free
 *  so the host never changes size during zoom — that is what keeps ResizeObserver
 *  / fit() / PTY resize off the zoom path — and scale(var(--zoom)) renders it at
 *  the right screen size.
 *
 *  It covers the BODY only, not the whole card. With the whole card in here the
 *  header rode along inside the scale, which at zoom > 1 is an UPSCALE of a 1×
 *  raster: terminal titles blurred while doc-card titles (laid out at real px per
 *  zoom) stayed sharp. Chrome does not need the zoom-free constraint the host
 *  does, so the two are split — the HtmlCard body box is the same idea. */
export function termInnerBox(): {
  width: string;
  height: string;
  transform: string;
  transformOrigin: string;
} {
  return {
    width: "var(--card-w)",
    height: `calc(var(--card-h) - ${CARD_HEADER_H_PX}px)`,
    transform: "scale(var(--zoom))",
    transformOrigin: "0 0",
  };
}
