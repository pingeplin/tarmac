// Where `key <card> contextmenu` right-clicks (spec 2609.0015, issue #166): the
// centre of the last cell that has a character in it, so xterm's
// rightClickSelectsWord produces a Range. A click on blank space yields a Caret,
// which would silently downgrade D5 into a second copy of D4 — hence S18's
// refusal rather than a best-effort point.
//
// `screenRect` must be the UNPATCHED rect —
// `Element.prototype.getBoundingClientRect.call(term.screenElement)`. xterm's
// getCoords reads the PATCHED one, and that is not an inconsistency but the
// algebra: TerminalCard's fakeBCR returns
// `left' = last − (last − r.left)/s`, `width' = r.w/s`, and by the time xterm
// reads it the leading mousemove (S16) has set `last` to the very point p we
// dispatched at, so xterm computes `x_rel = p − left'(p) = (p − r.left)/s` against
// the unpatched `r`. Setting that equal to the wanted
// `(col + 0.5)·r.w/(s·cols)` cancels `s` out entirely, leaving
// `p = r.left + (col + 0.5)·r.w/cols`.
//
// The caller passing the patched rect instead would feed a stale anchor — but be
// honest about how visible that is: it is NOT observable. Swapping
// `devDriver.ts`'s `Element.prototype` call for the patched rect was driven
// against a live app at zooms 1.05 through 2.9 with the most displaced target
// available, and every one still right-clicked the cell it aimed at, because the
// leading mousemove re-anchors the patched rect on the very point being
// dispatched and cancels most of the error back out (#174, recorded in
// `desktop/qa/qa-driver-qa.md`; the spec's S17 is corrected to match). The
// unpatched rect stands on the algebra above, not on a test — no test at any
// tier can tell the difference.

import type { Point, Rect } from "./geom";

export interface CellPointInput {
  /** The VIEWPORT's rows, top-first — not the scrollback window. xterm resolves
   *  a viewport cell, so the row index must be one, and `lines.length` is the
   *  grid's row count. */
  lines: string[];
  screenRect: Rect;
  cols: number;
}

export type CellPoint = Point | { error: "empty_buffer"; message: string };

export function devCellPoint(input: CellPointInput): CellPoint {
  const { lines, screenRect: r, cols } = input;
  const rows = lines.length;
  for (let row = rows - 1; row >= 0; row--) {
    const written = lines[row].replace(/\s+$/, "").length;
    if (written === 0) continue;
    const col = written - 1;
    return { x: r.x + (col + 0.5) * (r.w / cols), y: r.y + (row + 0.5) * (r.h / rows) };
  }
  return {
    error: "empty_buffer",
    message: "the terminal's viewport holds no text to right-click; a blank cell yields a caret, not a selection",
  };
}
