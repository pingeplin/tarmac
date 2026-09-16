// The QA driver's snapshot (spec 2609.0015, issue #166): the app's live UI state
// as plain JSON, so an outside process can read screen rects, focus, selection
// and terminal facts that exist nowhere but inside the webview.
//
// Pure by construction — it takes rects, cards and the measured DOM facts by
// argument and never reaches for `document`. Its test file runs in Vitest's node
// environment, where reaching for one would throw.
//
// Two coordinate/id conventions meet here and both are deliberate:
//   - ids on the wire are BARE (a term id, or a doc's absolute path), while
//     `model.ts`'s cardId() prefixes them (`term:`/`doc:`). The strip lives here
//     and nowhere else.
//   - `screen_rect` is client CSS px, so the projection adds the board view's own
//     origin on top of the world->view transform the board itself uses.

import { worldToView } from "./boardTransform";
import type { Rect } from "./geom";

export type DevVisibility = "visible" | "hidden";
export type DevSelectionType = "None" | "Caret" | "Range";

export interface DevViewport {
  zoom: number;
  cx: number;
  cy: number;
}

/** What the shell measured off one terminal, ready to be reported. */
export interface DevTermInput {
  cols: number;
  rows: number;
  /** The daemon's last TermProc name; null when it has never reported one. */
  proc: string | null;
  /** xterm's current selection; null (never "") when there is none. */
  selection: string | null;
  /** The buffer's lines, top to bottom. */
  lines: string[];
  /** The cursor's absolute line index (xterm's `baseY + cursorY`). */
  cursorLine: number;
}

export interface DevCardInput {
  /** The app-internal, prefixed id (`term:t-1`, `doc:/a/b.md`). */
  id: string;
  kind: "term" | "doc";
  frame: Rect;
  live?: boolean;
  dead?: boolean;
  term?: DevTermInput;
}

export interface DevSnapshotInput {
  boardId: string;
  visibilityState: DevVisibility;
  viewport: DevViewport;
  /** The board view's own client rect — what turns board-local into client px. */
  viewRect: Rect;
  /** The ACTIVE board's cards, in the order they should be reported. */
  cards: DevCardInput[];
  /** Measured client rects, keyed by the internal id. A card with no entry is
   *  reported unmeasured rather than invented. */
  screenRects: Map<string, Rect>;
  /** `App.tsx`'s selectedId — prefixed, like every other internal id. */
  selectedId: string | null;
  activeElement: {
    /** Already bare: the caller resolves it off `.term-host`'s data-term-id. */
    card: string | null;
    tag: string;
    classes: string[];
    selectionType: DevSelectionType;
  };
}

export interface DevSnapshotTerm {
  alive: boolean;
  cols: number;
  rows: number;
  proc: string | null;
  selection: string | null;
  scrollback_tail: string;
}

export interface DevSnapshotCard {
  id: string;
  kind: "term" | "doc";
  board_rect: Rect;
  screen_rect: Rect | null;
  focused: boolean;
  term?: DevSnapshotTerm;
}

export interface DevSnapshot {
  v: 1;
  board_id: string;
  visibility: DevVisibility;
  viewport: DevViewport & { view_rect: Rect };
  cards: DevSnapshotCard[];
  focused_card: string | null;
  active_element: {
    card: string | null;
    tag: string;
    classes: string[];
    selection_type: DevSelectionType;
  };
}

const TERM_PREFIX = "term:";
const DOC_PREFIX = "doc:";

/** `term:t-1` -> `t-1`, `doc:/a/b.md` -> `/a/b.md`. Anything else is returned
 *  unchanged, so this is safe to apply twice. */
export function bareCardId(internalId: string): string {
  if (internalId.startsWith(TERM_PREFIX)) return internalId.slice(TERM_PREFIX.length);
  if (internalId.startsWith(DOC_PREFIX)) return internalId.slice(DOC_PREFIX.length);
  return internalId;
}

/** The inverse, resolved against the cards that actually exist: a bare id from
 *  the wire becomes the internal id the app keys everything by. `null` when no
 *  card matches — including for an already-prefixed id, which is not the CLI's
 *  contract and would mask an implementation that never strips. */
export function internalCardId(bare: string, cards: DevCardInput[]): string | null {
  return cards.find((c) => bareCardId(c.id) === bare)?.id ?? null;
}

/** How many lines of context `scrollback_tail` carries. */
export const SCROLLBACK_TAIL_LINES = 40;

/** The 40 buffer lines ENDING AT THE CURSOR, not the last 40 of the buffer:
 *  `buffer.active.length` is `baseY + rows`, so on a tall card with little output
 *  the last 40 lines are all blank and every `contains` assertion would fail
 *  against output plainly on screen. */
export function scrollbackTail(lines: string[], cursorLine: number): string {
  const end = Math.min(cursorLine, lines.length - 1);
  const start = Math.max(0, end - SCROLLBACK_TAIL_LINES + 1);
  return lines.slice(start, end + 1).join("\n");
}

/** Board units -> client CSS px. The board's own transform is world-relative to
 *  the viewport's centre; the view rect's origin is what makes the result a
 *  client coordinate rather than a board-local one. */
export function boardRectToScreenRect(r: Rect, vp: DevViewport, viewRect: Rect): Rect {
  const centre = { x: vp.cx, y: vp.cy };
  const viewportCentre = { x: viewRect.x + viewRect.w / 2, y: viewRect.y + viewRect.h / 2 };
  const tl = worldToView({ x: r.x, y: r.y }, vp.zoom, centre, viewportCentre);
  const br = worldToView({ x: r.x + r.w, y: r.y + r.h }, vp.zoom, centre, viewportCentre);
  return { x: tl.x, y: tl.y, w: br.x - tl.x, h: br.y - tl.y };
}

export function buildSnapshot(input: DevSnapshotInput): DevSnapshot {
  const focusedCard = input.selectedId === null ? null : bareCardId(input.selectedId);
  return {
    v: 1,
    board_id: input.boardId,
    visibility: input.visibilityState,
    viewport: { ...input.viewport, view_rect: input.viewRect },
    cards: input.cards.map((c) => {
      const measured = input.screenRects.get(c.id);
      const card: DevSnapshotCard = {
        id: bareCardId(c.id),
        kind: c.kind,
        board_rect: c.frame,
        screen_rect: measured ? boardRectToScreenRect(c.frame, input.viewport, input.viewRect) : null,
        focused: focusedCard !== null && bareCardId(c.id) === focusedCard,
      };
      // Assigned rather than spread with a possibly-undefined value: a `term`
      // key set to undefined reads as an unresolvable path to `--until`, which
      // silently evaluates false instead of saying the card has no terminal.
      if (c.term) {
        card.term = {
          alive: c.live === true && c.dead !== true,
          cols: c.term.cols,
          rows: c.term.rows,
          proc: c.term.proc,
          selection: c.term.selection,
          scrollback_tail: scrollbackTail(c.term.lines, c.term.cursorLine),
        };
      }
      return card;
    }),
    focused_card: focusedCard,
    active_element: {
      card: input.activeElement.card,
      tag: input.activeElement.tag,
      classes: input.activeElement.classes,
      selection_type: input.activeElement.selectionType,
    },
  };
}
