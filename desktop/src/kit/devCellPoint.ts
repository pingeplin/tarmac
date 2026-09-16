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
// `p = r.left + (col + 0.5)·r.w/cols`. Passing the patched rect instead feeds a
// STALE anchor — whatever the last real mouse event left — and lands a full cell
// or more off at zoom 1.7.

export interface CellPointInput {
  /** The VIEWPORT's rows, top-first — not the scrollback window. xterm resolves
   *  a viewport cell, so the row index must be one. */
  lines: string[];
  screenRect: { x: number; y: number; w: number; h: number };
  cols: number;
  rows: number;
}

export type CellPoint =
  | { x: number; y: number }
  | { error: "empty_buffer"; message: string };

export function devCellPoint(input: CellPointInput): CellPoint {
  const { lines, screenRect: r, cols, rows } = input;
  for (let row = Math.min(lines.length, rows) - 1; row >= 0; row--) {
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
