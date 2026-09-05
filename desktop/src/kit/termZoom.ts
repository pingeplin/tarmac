// Pure module: terminal-card zoom layout. The outer wrapper is the SAME
// translate-only box every card type uses (docZoom's docWrapperBox); what is
// terminal-specific is termInnerBox: zoom-free (var(--card-w/h)) with a single
// scale(var(--zoom)), so the host never resizes on zoom → no fit()/PTY resize.

import { CARD_HEADER_H_PX } from "./cardChrome";

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
