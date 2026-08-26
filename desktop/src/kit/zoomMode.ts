// Pure decision logic for magnify (no re-wrap) zoom mode on HTML cards (spec
// 2607.0006). The shim is a dumb sensor/actuator; every verdict — declared
// mode, capability, effective mode — lives here so it is unit-testable.

export type ZoomMode = "magnify" | "reveal";

/** Root zoom the shim applies to the probe. Mirrored in card_shim.js — the
 *  two must be kept in sync (the socket_path() duplication precedent). */
export const ZOOM_PROBE_FACTOR = 2;

/** = 1 / ZOOM_PROBE_FACTOR. The layout viewport must SHRINK under zoom, not
 *  grow by it — a ratio of 1.0 means zoom had no effect on the ICB. */
export const ZOOM_PROBE_EXPECTED_RATIO = 1 / ZOOM_PROBE_FACTOR;

/** Allowed |measured ratio − expected ratio|. Boundary is inclusive; never
 *  asserted by a test — IEEE-754 rounding makes it undecidable. */
export const ZOOM_PROBE_TOLERANCE = 0.02;

// Trimmed, case-insensitive "magnify" opts in; everything else (including
// Magnify is the DEFAULT: an agent writing a report does not know to ask for a
// stable layout, and a document that re-wraps as you zoom is the wrong default
// for the thing most HTML cards are. Only a deliberate, well-formed "reveal"
// opts out — that is the case with a real reason behind it (a self-contained
// D3/Canvas dashboard needing honest viewport dimensions, spec 2607.0004 S6),
// so it is worth spelling. Malformed values take the default rather than
// silently landing in the mode almost nobody wants.
//
// The default lives here, not as markup injected by the shim: this module is
// where every zoom verdict lives so it stays unit-testable, and injecting a tag
// the author never wrote would make the served document lie about its source.
export function declaredZoomMode(metaContent: string | null | undefined): ZoomMode {
  return metaContent?.trim().toLowerCase() === "reveal" ? "reveal" : "magnify";
}

// true iff base and zoomed are finite, base > 0, and the measured ratio is
// within tolerance of ZOOM_PROBE_EXPECTED_RATIO. The base > 0 guard is load-
// bearing on its own: {base: -400, zoomed: -200} has ratio exactly 0.5 and
// would otherwise pass.
export function zoomCapable(probe: { base: number; zoomed: number }): boolean {
  const { base, zoomed } = probe;
  if (!Number.isFinite(base) || !Number.isFinite(zoomed) || base <= 0) return false;
  return Math.abs(zoomed / base - ZOOM_PROBE_EXPECTED_RATIO) <= ZOOM_PROBE_TOLERANCE;
}

export function effectiveZoomMode(declared: ZoomMode, capable: boolean): ZoomMode {
  return declared === "magnify" && capable ? "magnify" : "reveal";
}
