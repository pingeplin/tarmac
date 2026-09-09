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

/** A screen-px wheel delta in the card document's own layout units. Magnify
 *  freezes the document at root zoom K inside a frame×K box under scale(zoom/K),
 *  so one screen px is 1/zoom of a local unit; reveal lays the document out at
 *  real screen px, where the two are already 1:1. */
export function cardScrollDelta(deltaPx: number, zoom: number, magnify: boolean): number {
  return magnify && zoom > 0 ? deltaPx / zoom : deltaPx;
}

/** A relayed scroll split into a whole-px step plus the sub-px residue to carry
 *  into the next event (spec 2609.0013, #142). cardScrollDelta divides by board
 *  zoom, so at any non-integer zoom the delta reaching the document is
 *  fractional — and a fractional scrollBy is what leaves the unpainted band.
 *  Rounding alone would stall a slow trackpad, whose per-event delta rounds to
 *  zero, so the residue is carried rather than discarded: travel is conserved. */
export function quantizeScrollDelta(delta: number, carry: number): { step: number; carry: number } {
  const total = delta + carry;
  const step = Math.round(total);
  return { step, carry: total - step };
}

/** One wheel event reduced to what the relay should send and remember. Pure, not
 *  inline in the handler, so that its three load-bearing decisions are assertable:
 *  carries written back even when nothing is posted, suppression only when BOTH
 *  axes are zero, and each axis on its own delta (spec 2609.0013 S11-S14). */
export function relayScrollStep(
  dx: number,
  dy: number,
  carryX: number,
  carryY: number,
): { dx: number; dy: number; carryX: number; carryY: number; post: boolean } {
  const x = quantizeScrollDelta(dx, carryX);
  const y = quantizeScrollDelta(dy, carryY);
  return {
    dx: x.step,
    dy: y.step,
    carryX: x.carry,
    carryY: y.carry,
    post: x.step !== 0 || y.step !== 0,
  };
}

/** A stateful wheel relay: holds the per-axis carry across events. The ordering
 *  — write the carry back BEFORE deciding not to post — lives here rather than in
 *  the component because an ordering inside the untested React shell is invisible
 *  to every test (spec 2609.0013 S15). One instance per live handler. */
export function createScrollRelay(): (
  dx: number,
  dy: number,
) => { dx: number; dy: number; post: boolean } {
  let carryX = 0;
  let carryY = 0;
  return (dx, dy) => {
    const r = relayScrollStep(dx, dy, carryX, carryY);
    carryX = r.carryX;
    carryY = r.carryY;
    return { dx: r.dx, dy: r.dy, post: r.post };
  };
}

// Mid-gesture transform: the iframe keeps its settled px size and scales by
// the ratio of live zoom to the zoom it was last sized at.
export function cardGestureScale(zoom: number, settledZoom: number): number {
  return zoom / settledZoom;
}
