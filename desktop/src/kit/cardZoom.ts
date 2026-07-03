// Real-px iframe sizing for HTML cards (spec 2607.0004). Unlike doc prose,
// a foreign iframe document cannot be oversample-then-downscaled (docZoom.ts),
// so the iframe is laid out at true screen resolution: sized to the settled
// real-px box, with a temporary CSS scale during pan/zoom gestures and a
// resize on settle (RASTER_SCALE_SETTLE_MS in rasterScale.ts).

export interface CardFrameSize {
  w: number;
  h: number;
}

// The settled iframe box in screen px for a world-frame at a given zoom.
export function cardIframePx(frame: CardFrameSize, zoom: number): CardFrameSize {
  return { w: Math.round(frame.w * zoom), h: Math.round(frame.h * zoom) };
}

// Mid-gesture transform: the iframe keeps its settled px size and scales by
// the ratio of live zoom to the zoom it was last sized at.
export function cardGestureScale(zoom: number, settledZoom: number): number {
  return zoom / settledZoom;
}
