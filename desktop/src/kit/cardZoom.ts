// Real-px iframe sizing for HTML cards (spec 2607.0004). Unlike doc prose,
// a foreign iframe document cannot be oversample-then-downscaled (docZoom.ts),
// so the iframe is laid out at true screen resolution: sized to the settled
// real-px box, with a temporary CSS scale during pan/zoom gestures and a
// resize on settle (RASTER_SCALE_SETTLE_MS in rasterScale.ts).

export interface CardFrameSize {
  w: number;
  h: number;
}

/** Frozen root zoom for magnify mode. Tracking board zoom (the 2607.0006 shape)
 *  re-runs layout at a NEW zoom value on every settle, and WebKit does not scale
 *  glyph advances linearly across those values — ffddbfa measured one paragraph
 *  at 9/7/7/6 lines over z=0.5..3 while the ICB never moved. Freezing the root
 *  zoom removes the variable: layout runs once, at this factor, and never again,
 *  so a wrap point cannot move. Must be >= BoardEngine MAX_ZOOM so the outer
 *  scale(zoom/K) is always a DOWN-scale (crisp, never an upsample). */
export const MAGNIFY_K = 3;

// The settled iframe box in screen px for a world-frame at a given zoom.
export function cardIframePx(frame: CardFrameSize, zoom: number): CardFrameSize {
  return { w: Math.round(frame.w * zoom), h: Math.round(frame.h * zoom) };
}

// Mid-gesture transform: the iframe keeps its settled px size and scales by
// the ratio of live zoom to the zoom it was last sized at.
export function cardGestureScale(zoom: number, settledZoom: number): number {
  return zoom / settledZoom;
}
