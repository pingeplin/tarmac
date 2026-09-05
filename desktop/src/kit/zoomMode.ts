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
  /** The mode to adopt for this load, or null to keep the one in force. */
  adopt: ZoomMode | null;
  /** The once-per-load console line, or null to log nothing. */
  logLine: string | null;
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
    adopt: inForce === null ? declared : null,
    // Keyed on the tag being PRESENT, not on the resolved mode: an empty or
    // malformed content is a tag the author wrote, and only an absent one is
    // silent. declared and effective read the same since the capability probe
    // that split them died with the macOS 26 floor (#94); the line keeps both
    // halves because its job is to name the mode in force for a document whose
    // meta may be a typo, and `declared` is the resolved value, not the raw tag.
    logLine:
      inForce === null && meta !== null
        ? `zoom-mode declared=${declared} effective=${declared}`
        : null,
    zoomPost: effective === "magnify" ? { tarmac: "zoom", z: MAGNIFY_K } : null,
  };
}
