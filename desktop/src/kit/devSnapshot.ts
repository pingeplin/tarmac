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
  /** xterm's current selection, verbatim — including the "" it reports when
   *  there is none. `buildSnapshot` normalises that to null. */
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
  /** Measured client rects, keyed by the internal id — what the card's DOM node
   *  actually reports. A card with no entry is reported unmeasured (`null`)
   *  rather than invented. These are REPORTED AS MEASURED, never replaced by the
   *  projection: `screen_rect` exists so a scenario can compare where a card is
   *  painted against where the transform says it should be, and a projected value
   *  would make that comparison an identity. */
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
  /** The hold-⌘Q guard's own facts (#171, #183), or null when the backend did
   *  not answer — a release build, or one without the command. */
  quitGuard: DevQuitGuard | null;
  /** `App.tsx`'s borrowedCardId — prefixed, like every other internal id. */
  borrowedId: string | null;
}

export interface DevQuitGuard {
  retargeted: boolean;
  enabled: boolean;
  phase: "idle" | "showing" | "confirming";
  notice: { visible: boolean; alpha: number };
  last_press: { press_ms: number; route: "guard" | "terminate"; age_ms: number } | null;
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
  /** Doc cards only: whether this is the HTML card whose shield is lifted. */
  borrowed?: boolean;
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
  quit_guard: DevQuitGuard | null;
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

/** How many lines of context `scrollback_tail` carries. */
export const SCROLLBACK_TAIL_LINES = 40;

/** The rows `scrollback_tail` will keep: the 40 ENDING AT THE CURSOR, not the last
 *  40 of the buffer. `buffer.active.length` is `baseY + rows`, so on a tall card
 *  with little output the last 40 lines are all blank and every `contains`
 *  assertion would fail against output plainly on screen.
 *
 *  Exported because the caller reading xterm needs the same bounds: a terminal
 *  keeps 5000 lines of scrollback and only these ~40 are ever reported, so
 *  materialising the rest — once per 50 ms `--until` poll — is pure waste. */
export function tailWindowBounds(cursorLine: number, length: number): { start: number; end: number } {
  const end = Math.min(cursorLine, length - 1);
  return { start: Math.max(0, end - SCROLLBACK_TAIL_LINES + 1), end };
}

/** `lines` may be the whole buffer or just the `tailWindowBounds` window of it;
 *  `cursorLine` is absolute either way, so both give the same answer. */
export function scrollbackTail(lines: string[], cursorLine: number): string {
  const { start, end } = tailWindowBounds(cursorLine, lines.length);
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
        // The measurement itself. Reporting `boardRectToScreenRect(c.frame, …)`
        // here instead would make D1 compare the projection with itself.
        screen_rect: measured ?? null,
        focused: focusedCard !== null && bareCardId(c.id) === focusedCard,
      };
      if (c.kind === "doc") card.borrowed = c.id === input.borrowedId;
      // Assigned rather than spread with a possibly-undefined value: a `term`
      // key set to undefined reads as an unresolvable path to `--until`, which
      // silently evaluates false instead of saying the card has no terminal.
      if (c.term) {
        card.term = {
          alive: c.live === true && c.dead !== true,
          cols: c.term.cols,
          rows: c.term.rows,
          proc: c.term.proc,
          // xterm reports "" for no selection; "" would make `contains ""` match
          // vacuously, so the normalisation is a decision and lives here rather
          // than in the shell that reads it.
          selection: c.term.selection || null,
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
    quit_guard: input.quitGuard && {
      ...input.quitGuard,
      // `hide_notice` resets a hidden panel's alphaValue to 1.0, which would
      // read as a notice at full opacity.
      notice: {
        visible: input.quitGuard.notice.visible,
        alpha: input.quitGuard.notice.visible ? input.quitGuard.notice.alpha : 0,
      },
    },
  };
}
