// Pure decision logic for magnify (no re-wrap) zoom mode on HTML cards (spec
// 2607.0006, frozen-K per docs/designs/2608.0001; the per-ready verdict is spec
// 2609.0003). The shim is a dumb sensor/actuator and the React shell has no unit
// tests, so every zoom verdict lives here to stay testable.

import { MAGNIFY_K } from "./cardZoom";

export type ZoomMode = "magnify" | "reveal";

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

export interface CardZoomPost {
  tarmac: "zoom";
  z: number;
}

export interface ReadyActions {
  /** This ready's own declaration. Inert whenever logMode is false. */
  declared: ZoomMode;
  /** The mode to adopt for this load, or null to keep the one in force. */
  adopt: ZoomMode | null;
  /** Emit the once-per-load `zoom-mode declared=… effective=…` line. */
  logMode: boolean;
  /** What to post to the document, or null to post nothing. */
  zoomPost: CardZoomPost | null;
}

/**
 * What the host does with one `ready` from a card (spec 2609.0003, issue #99).
 *
 * A document that reloads ITSELF changes neither `src` nor `lastChangedMs`, so
 * the host's per-load state is never reset and its `ready` arrives with a mode
 * already in force. Before #99 that ready was discarded whole and the reloaded
 * document was sent no root zoom at all — leaving it laid out in a K× viewport
 * inside a frame×K box, i.e. rendered at 1/K.
 *
 * The split: adopting a mode and logging the console line stay once-per-load
 * (2607.0006 S17 — a forged repeat must not flip the mode out from under the
 * strip), while the zoom post answers EVERY ready. Under frozen-K that post is
 * a constant, so re-asserting it is idempotent — the same reason #106's cull
 * post may answer every ready.
 *
 * A repeat decides from `inForce`, never from its own `meta`: otherwise a forged
 * `meta:"magnify"` would inject root zoom K into a reveal card.
 *
 * @param inForce the mode already adopted for THIS load, or null when no genuine
 *                ready has been honored yet.
 * @param meta    this ready's `<meta name="tarmac-zoom">` content (null = absent).
 */
export function readyActions(inForce: ZoomMode | null, meta: string | null): ReadyActions {
  const declared = declaredZoomMode(meta);
  const effective = inForce ?? declared;
  return {
    declared,
    adopt: inForce === null ? declared : null,
    // Keyed on the tag being PRESENT, not on the resolved mode: an empty or
    // malformed content is a tag the author wrote, and only an absent one is
    // silent.
    logMode: inForce === null && meta !== null,
    zoomPost: effective === "magnify" ? { tarmac: "zoom", z: MAGNIFY_K } : null,
  };
}
