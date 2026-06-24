// Board card models. World-space frames (the board transform scales them); the
// BoardEngine never reprojects these per frame — they only change on committed
// events (spawn/open/drag-end/exit), which is when React re-renders.
//
// BoardState: per-board slice of the App state (P5 multi-board).

import type { Viewport } from "./BoardEngine";

/** Per-doc metadata kept off the card (so a shelved doc keeps its color/owner).
 * Moved here from App so the per-board BoardState can own it. */
export interface DocMeta {
  repoColor?: number;
  ownerTermId?: string;
  /** Repo identity for the peek's repo-qualified displayPath (head-truncated). */
  repo?: string;
  repoRoot?: string;
  /** REAL last file-change time (wire last_changed_ms / file_event mtime_ms), NOT
   *  doc-open time — drives the on-card + peek "✎ Ns" recency meta. undefined ⇒ no meta. */
  lastChangedMs?: number;
}

/** The mutable whiteboard state owned by one board. Backed by the warm-board
 * "render-all, hide-inactive" model: every board's cards stay mounted even
 * when backgrounded so their xterm terminals keep streaming output. */
export interface BoardState {
  cards: CardModel[];
  shelfPaths: string[];
  /** doc-open order — peek-target fallback (most-recently-opened last). */
  dockOrder: string[];
  /** Per-doc metadata (color + provenance) for all docs this board has ever seen. */
  docMeta: Map<string, DocMeta>;
  /** Last-committed viewport; seeded from restore. */
  viewport: Viewport;
  /** True after the first restore for this board (first-visit latch). */
  didRestore: boolean;
  /** Runtime-only: the prime terminal id docked into the shared bottom pane on this
   *  board, or null. Latched intent — survives board switch (undock-on-leave /
   *  re-dock-on-arrive) but is NEVER persisted (Swift dock is client-only). */
  dockedTermId: string | null;
}

/** A fresh, empty board state. Seeded as the synthetic local board before the
 * first real restore arrives from the daemon. */
export function emptyBoardState(): BoardState {
  return {
    cards: [],
    shelfPaths: [],
    dockOrder: [],
    docMeta: new Map(),
    viewport: { zoom: 1, cx: 0, cy: 0 },
    didRestore: false,
    dockedTermId: null,
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

export const cardId = (c: CardModel): string =>
  c.kind === "term" ? `term:${c.termId}` : `doc:${c.path}`;

/** Highest z among a card set (for select-to-front: new front = topZ + 1). */
export const topZ = (cards: CardModel[]): number =>
  cards.reduce((m, c) => Math.max(m, c.z), 0);
