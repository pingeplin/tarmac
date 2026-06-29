// Port of TarmacKit/BoardSwitcher.swift — the pure view-model for the ⌘K boards
// switcher (M3 P4). The prefix filter, the ⌘1..9 / ⏎ ordinal map, the selection
// clamp, and the meta-line formatting live here so they stay testable away from
// AppKit. The app gathers per-board facts into `BoardSummary`s, asks for
// `rows(...)`, and renders the result. This replaced the former cycling
// `BoardRegistry`: the switcher does not cycle, and its ⌘1..9 jump must address
// the *visible* (filtered) rows, not the full board list.

/// One board's live facts, gathered by the app for the switcher. The app can
/// derive these locally for boards it has visited (their cards + signals stay
/// alive while backgrounded); a never-visited board reports `cards === 0` and
/// `isLive === false` until its first restore.
export interface BoardSummary {
  boardID: string;
  /** User-given display name, or null → falls back to the slug `boardID`. */
  name: string | null;
  /** Terminal cards with a live (cyan) foreground signal. */
  running: number;
  /** Cards with an unacked bell (amber) signal. */
  bell: number;
  /** Total cards on the board. */
  cards: number;
  /** Whether the board has any live pty — drives the cyan-vs-faint strip glyph. */
  isLive: boolean;
}

/// A switcher row ready to render: the resolved display label, the active flag
/// (selected-style highlight is separate, driven by keyboard), the glyph/spinner
/// inputs, and the formatted meta line.
export interface BoardRow {
  boardID: string;
  display: string;
  isActive: boolean;
  isLive: boolean;
  running: number;
  bell: number;
  cards: number;
  meta: string;
}

/** What a summary's row shows: the display name, else the slug. */
function displayOf(s: BoardSummary): string {
  return s.name ?? s.boardID;
}

/**
 * Builds the visible rows from the summaries, an `active` board id, and the
 * typed `filter`. The filter is a case-insensitive **prefix** match on the
 * display label (prefix + row-order; fuzzy deferred); an empty filter keeps
 * every board. Display order is preserved.
 */
export function rows(summaries: BoardSummary[], active: string, filter: string): BoardRow[] {
  const q = filter.toLowerCase();
  return summaries
    .filter((s) => q === "" || displayOf(s).toLowerCase().startsWith(q))
    .map((s) => {
      const display = displayOf(s);
      return {
        boardID: s.boardID,
        display,
        isActive: s.boardID === active,
        isLive: s.isLive,
        running: s.running,
        bell: s.bell,
        cards: s.cards,
        meta: meta(s.running, s.bell, s.cards),
      };
    });
}

/**
 * The board id at 1-based ordinal `n` among the *visible* rows (⌘1..9 jump / ⏎
 * when the panel maps Enter to the highlighted row). undefined when out of range.
 */
export function boardIdForOrdinal(n: number, rowList: BoardRow[]): string | undefined {
  if (n < 1 || n > rowList.length) return undefined;
  return rowList[n - 1].boardID;
}

/**
 * Clamps a selection index into `[0, count-1]` (0 when empty) after a filter
 * change or an ↑/↓ move — selection does not wrap.
 */
export function clampSelection(index: number, count: number): number {
  if (count <= 0) return 0;
  return Math.min(Math.max(0, index), count - 1);
}

// --- P5.4 rename / delete validation (mirrors the daemon's authority) ---

/**
 * Whether a board may be deleted: only when more than one exists (a board set is
 * never empty). Mirrors the daemon's last-board refusal so the switcher never
 * even arms the delete confirm for the last board.
 */
export function canDelete(boardCount: number): boolean {
  return boardCount > 1;
}

/**
 * Normalizes a typed rename: trims surrounding whitespace; a blank/whitespace-
 * only name collapses to "" — which the daemon maps to "clear the name back to
 * the slug" rather than setting a blank visible name.
 *
 * Swift trims `.whitespacesAndNewlines`: ASCII/Unicode spaces, tabs, and
 * newlines. JS `String.prototype.trim` removes the same WhiteSpace + LineTerminator
 * set, so it matches for the inputs this normalizes.
 */
export function sanitizedName(raw: string): string {
  return raw.trim();
}

/**
 * Whether a typed scalar should feed the switcher filter / rename buffer — a real
 * printable character. Excludes control chars (< 0x20), DEL (0x7f), and the
 * AppKit function/arrow/navigation keys, which `NSEvent.characters` delivers as
 * private-use scalars in 0xF700–0xF8FF (e.g. NSUpArrowFunctionKey = 0xF700):
 * without this they would be appended as garbage glyphs.
 */
export function isTypable(scalar: number): boolean {
  return scalar >= 0x20 && scalar !== 0x7f && !(scalar >= 0xf700 && scalar <= 0xf8ff);
}

/**
 * Resolve a board's switcher liveness from the app's local card signals and the
 * daemon's reported live-pty count. For a board the app has **visited** this
 * session the local signals are authoritative (its cards + live views stay alive
 * while backgrounded, so they don't flicker against the daemon's count). For a
 * **never-visited** board (no local view yet) the daemon's `running` count is the
 * only honest source of liveness; a missing report (null) is treated as zero.
 */
export function liveness(
  visited: boolean,
  localRunning: number,
  localIsLive: boolean,
  daemonRunning: number | null,
): { running: number; isLive: boolean } {
  if (visited) return { running: localRunning, isLive: localIsLive };
  const r = Math.max(0, daemonRunning ?? 0);
  return { running: r, isLive: r > 0 };
}

/**
 * The row meta line: `"N running · M bell · K cards"`, dropping the running and
 * bell segments when zero; the card count is always shown (singular "1 card").
 * The leading spinner and the glyph colors are the view's job.
 */
export function meta(running: number, bell: number, cards: number): string {
  const parts: string[] = [];
  if (running > 0) parts.push(`${running} running`);
  if (bell > 0) parts.push(`${bell} bell`);
  parts.push(cards === 1 ? "1 card" : `${cards} cards`);
  return parts.join(" · ");
}
