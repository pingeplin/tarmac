// Pure module: terminal-card zoom layout. The outer wrapper is the SAME
// translate-only box every card type uses (docZoom's docWrapperBox); what is
// terminal-specific is termInnerBox: zoom-free (var(--card-w/h)) with a single
// scale(var(--zoom)), so a zoom gesture alone never resizes the host.

import { CARD_BORDER_W_PX, CARD_HEADER_H_PX } from "./cardChrome";

/** What `.card-body` actually leaves the host on each axis, in world px: the
 *  card minus its header and minus BOTH borders. Subtracting the header alone
 *  overhung the body by 2·zoom px, which `.card-body { overflow: hidden }` then
 *  clipped off the bottom of the terminal (spec 2609.0011). */
const BODY_INSET_V = CARD_HEADER_H_PX + 2 * CARD_BORDER_W_PX;
const BODY_INSET_H = 2 * CARD_BORDER_W_PX;

/** Zoom-free host box, living INSIDE the card body. Width/height are zoom-free,
 *  and scale(var(--zoom)) renders the box at the right screen size, so panning
 *  and zooming within one rasterScale step never touch the host's layout size.
 *  (A rasterScale STEP does resize it — the raster wrapper goes rs×100% — which
 *  is why the grid rules in kit/termGrid.ts distinguish the two cases rather
 *  than assuming the ResizeObserver only ever sees card resizes.)
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
    width: `calc(var(--card-w) - ${BODY_INSET_H}px)`,
    height: `calc(var(--card-h) - ${BODY_INSET_V}px)`,
    transform: "scale(var(--zoom))",
    transformOrigin: "0 0",
  };
}
