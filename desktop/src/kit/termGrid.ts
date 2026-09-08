// Pure module: the terminal grid a card's box can actually hold.
//
// This replaces `@xterm/addon-fit`, which measures the WRONG BOX: it reads
// `getComputedStyle(term.element.parentElement).height` — the .term-host — and
// subtracts only the padding of `term.element` (.xterm, which has none). Under
// the global `* { box-sizing: border-box }` that height INCLUDES the host's
// padding, while `.term-host .xterm { height: 100% }` resolved to the content
// box, 24·rs px shorter. Rows were therefore counted against a box taller than
// the one the text is painted in, and the surplus row fell out of the card
// (spec 2609.0011, issue #130).
//
// Everything here is arithmetic on numbers the caller measured, so the rules are
// unit-testable — which the FitAddon call they replace never was.

/** A measured card box, in CSS px. */
export interface GridBox {
  /** .term-host padding box (host.clientHeight / host.clientWidth). */
  boxH: number;
  boxW: number;
  /** Padding inside that box the grid must not use: host + .xterm, already ×rs. */
  padV: number;
  padH: number;
  /** Width the scrollbar reserves; 0 when none is shown. */
  scrollbar: number;
  /** Renderer cell metrics (term.dimensions.css.cell). */
  cellW: number;
  cellH: number;
}

export interface Grid {
  cols: number;
  rows: number;
}

/** The card's own size, with the rasterScale factored out, so the same card
 *  compares equal whatever it is currently rasterised at. */
export interface CardBox {
  cardH: number;
  cardW: number;
}

/** The grid a card settled on at its current size, and the size it was measured
 *  at. A zoom may shrink below this but never past it, and never replaces it. */
export interface RestGrid extends CardBox {
  grid: Grid;
}

/** xterm's own floors (Terminal.resize clamps to these anyway). */
const MIN_COLS = 2;
const MIN_ROWS = 1;

/** Sub-pixel slack when comparing card boxes: clientHeight is an integer, so a
 *  box divided by a fractional rasterScale lands up to half a pixel off. Below a
 *  drag's 1px step, so a real resize is never mistaken for rounding noise. */
export const CARD_BOX_EPSILON = 0.75;

const usable = (v: number) => Number.isFinite(v) && v > 0;

/**
 * The grid that fits the box's CONTENT area, or null when the box cannot be
 * measured yet — zero cell metrics before the renderer has measured, an empty
 * box while the board is hidden (`display:none`), or a NaN from a failed
 * `parseFloat` of a computed style. Null means "propose nothing": a resize with
 * NaN throws inside xterm, and a resize to 2×1 would shrink a live program's PTY.
 */
export function proposeGrid(box: GridBox): Grid | null {
  const { boxH, boxW, padV, padH, scrollbar, cellW, cellH } = box;
  if (![boxH, boxW, cellW, cellH].every(usable)) return null;
  if (![padV, padH, scrollbar].every(Number.isFinite)) return null;
  return {
    cols: Math.max(MIN_COLS, Math.floor((boxW - padH - scrollbar) / cellW)),
    rows: Math.max(MIN_ROWS, Math.floor((boxH - padV) / cellH)),
  };
}

/** Per-axis minimum: keep the rest grid wherever it still fits, give up only
 *  the axis that no longer does. */
export function clampGrid(rest: Grid, proposed: Grid): Grid {
  return {
    cols: Math.min(rest.cols, proposed.cols),
    rows: Math.min(rest.rows, proposed.rows),
  };
}

/** The measured box with the rasterScale divided out — the card's own size. */
export function cardBox(box: GridBox, rasterScale: number): CardBox {
  return { cardH: box.boxH / rasterScale, cardW: box.boxW / rasterScale };
}

const sameCard = (a: CardBox, b: CardBox) =>
  Math.abs(a.cardH - b.cardH) <= CARD_BOX_EPSILON &&
  Math.abs(a.cardW - b.cardW) <= CARD_BOX_EPSILON;

/**
 * The grid to apply for a fresh measurement, and the rest grid to carry forward.
 *
 * The card is re-measured for two different reasons and the right answer differs:
 *
 *   - **The card was resized.** The proposal is the truth; it becomes the new
 *     rest grid.
 *   - **Only the rasterScale changed** (a board zoom settled). The oversampled
 *     cell is not a clean multiple of the 1× one — device-px rounding takes it
 *     21 → 31 → 43 → 53 → 63 — so a free re-measure moves cols×rows and
 *     SIGWINCHes the running program for a mere board gesture. Keep the rest
 *     grid wherever it still fits, and leave the rest grid itself alone so that
 *     zooming back out restores what zooming in gave up.
 *
 * The two are told apart by the card box, NOT by which observer fired: a
 * rasterScale commit resizes .term-host for real (288 → 432 px at rs 1.5), so
 * the ResizeObserver fires for zooms as well as for resizes and cannot be used
 * as the signal. Dividing the measured box by the rasterScale removes exactly
 * that difference and leaves the card's own size.
 */
export function nextGrid(
  proposed: Grid,
  rest: RestGrid | null,
  card: CardBox,
): { grid: Grid; rest: RestGrid } {
  if (rest && sameCard(rest, card)) {
    return { grid: clampGrid(rest.grid, proposed), rest };
  }
  return { grid: proposed, rest: { grid: proposed, ...card } };
}

/** What xterm's viewport reserves for its scrollbar, in CSS px. Mirrors the rule
 *  `@xterm/addon-fit` applied, which the grid budget has to keep honouring. */
export function scrollbarReserve(options: {
  scrollback?: number;
  scrollbar?: { showScrollbar?: boolean; width?: number };
}): number {
  if (options.scrollback === 0 || options.scrollbar?.showScrollbar === false) return 0;
  return options.scrollbar?.width ?? 14;
}
