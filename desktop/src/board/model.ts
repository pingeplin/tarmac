// Board card models. World-space frames (the board transform scales them); the
// BoardEngine never reprojects these per frame — they only change on committed
// events (spawn/open/drag-end/exit), which is when React re-renders.
//
// BoardState: per-board slice of the App state (P5 multi-board).

import type { Viewport } from "./BoardEngine";

/** Per-doc metadata kept off the card.
 * Moved here from App so the per-board BoardState can own it. */
export interface DocMeta {
  repoColor?: number;
  ownerTermId?: string;
  /** Repo identity for the repo-qualified displayPath (head-truncated). */
  repo?: string;
  repoRoot?: string;
  /** REAL last file-change time (wire last_changed_ms / file_event mtime_ms), NOT
   *  doc-open time — drives the on-card "✎ Ns" recency meta. undefined ⇒ no meta. */
  lastChangedMs?: number;
}

/** The mutable whiteboard state owned by one board. Backed by the warm-board
 * "render-all, hide-inactive" model: every board's cards stay mounted even
 * when backgrounded so their xterm terminals keep streaming output. */
export interface BoardState {
  cards: CardModel[];
  /** doc-open order (most-recently-opened last). */
  dockOrder: string[];
  /** Per-doc metadata (color + provenance) for all docs this board has ever seen. */
  docMeta: Map<string, DocMeta>;
  /** Last-committed viewport; seeded from restore. */
  viewport: Viewport;
  /** True after the first restore for this board (first-visit latch). */
  didRestore: boolean;
}

/** A fresh, empty board state. Seeded as the synthetic local board before the
 * first real restore arrives from the daemon. */
export function emptyBoardState(): BoardState {
  return {
    cards: [],
    dockOrder: [],
    docMeta: new Map(),
    viewport: { zoom: 1, cx: 0, cy: 0 },
    didRestore: false,
  };
}

export interface WorldFrame {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface TermCardModel {
  kind: "term";
  termId: string;
  frame: WorldFrame;
  /** Stacking order (persisted); higher = front. Select-to-front bumps it. */
  z: number;
  label: string;
  live: boolean;
  dead: boolean;
  prime: boolean;
  bell: boolean;
  /** A cold-spawn card (boot / ⌘T / restored-dead) cold-spawns a fresh shell when
   * it first measures cols/rows. A re-bound card (restore matched a daemon-live
   * pty) adopts the running shell instead — it attaches output but never spawns,
   * only syncing the pty size to the card. */
  needsSpawn: boolean;
  /** issue #77: on a cold spawn, the term_id whose LIVE cwd this card's shell
   * should inherit (e.g. ⌘T inheriting the prime terminal's current directory).
   * Only consulted while needsSpawn is true. */
  inheritCwdFrom?: string;
}

export interface DocCardModel {
  kind: "doc";
  path: string;
  frame: WorldFrame;
  /** Stacking order (persisted); higher = front. */
  z: number;
  /** The terminal that opened this doc (provenance edge + gravity owner). */
  ownerTermId?: string;
  repoColor?: number;
  fresh: boolean;
  /** Gravity-bound to its owner terminal (persisted as `loose = !attached`). A
   * manual drag detaches it (attached=false) so it no longer follows the owner. */
  attached: boolean;
}

export type CardModel = TermCardModel | DocCardModel;

/** The doc half of cardId(), for callers holding only a path. */
export const docCardId = (path: string): string => `doc:${path}`;

export const cardId = (c: CardModel): string =>
  c.kind === "term" ? `term:${c.termId}` : docCardId(c.path);

/** Highest z among a card set (for select-to-front: new front = topZ + 1). */
export const topZ = (cards: CardModel[]): number =>
  cards.reduce((m, c) => Math.max(m, c.z), 0);
