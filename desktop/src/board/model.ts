// Board card models. World-space frames (the board transform scales them); the
// BoardEngine never reprojects these per frame — they only change on committed
// events (spawn/open/drag-end/exit), which is when React re-renders.

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
