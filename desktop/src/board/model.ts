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
  label: string;
  live: boolean;
  dead: boolean;
  prime: boolean;
  bell: boolean;
}

export interface DocCardModel {
  kind: "doc";
  path: string;
  frame: WorldFrame;
  /** The terminal that opened this doc (provenance edge + gravity owner). */
  ownerTermId?: string;
  repoColor?: number;
  fresh: boolean;
}

export type CardModel = TermCardModel | DocCardModel;

export const cardId = (c: CardModel): string =>
  c.kind === "term" ? `term:${c.termId}` : `doc:${c.path}`;
