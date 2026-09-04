// Pure decision logic for magnify (no re-wrap) zoom mode on HTML cards (spec
// 2607.0006, frozen-K per docs/designs/2608.0001). The shim is a dumb
// sensor/actuator; the mode verdict lives here so it is unit-testable.

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
