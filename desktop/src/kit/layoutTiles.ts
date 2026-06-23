// The board ↔ layout-tile codec (ported from AppController.boardTile +
// applyRestoredLayout): turns the live card set into the wire `tiles[]` the
// `layout` message persists, and parses a restored `tiles[]` back into the term /
// doc / shelf placements the board rebuilds from. Kept pure (no React, no DOM, no
// IPC types) so it is unit-tested and the round-trip is verifiable in isolation.
//
// Wire shape (tarmac_protocol::Tile) — every key snake_case, `z` an integer:
//   { kind: "term"|"doc", path?, x?, y?, w?, h?, z?, loose?, shelf?, term_id? }
// A term tile carries term_id + geometry; a board doc tile carries path +
// geometry + loose(=!attached); a shelf doc tile carries path + shelf:true +
// loose:true and NO geometry. Tiles with all-nil geometry are M1 (grid-scatter).

import type { Rect } from "./geom";

/** One persisted tile (structurally identical to ipc `WireTile`). */
export interface LayoutTile {
  kind: string;
  path?: string;
  x?: number;
  y?: number;
  w?: number;
  h?: number;
  z?: number;
  loose?: boolean;
  shelf?: boolean;
  term_id?: string;
}

/** A live terminal card, as the board knows it, ready to persist. */
export interface TermTileInput {
  termId: string;
  frame: Rect;
  z: number;
  /** Exited/hold-open placeholders are never persisted (Swift persistedTermIDs). */
  dead: boolean;
}

/** A live doc card on the board. `attached` true ⇒ still gravity-bound (loose=false). */
export interface DocTileInput {
  path: string;
  frame: Rect;
  z: number;
  attached: boolean;
}

/** A terminal placement parsed from a restored tile. `frame` is undefined for an
 * M1 geometry-less tile (caller applies a default/scatter); `termId` is null for
 * a legacy single-terminal tile (caller mints/cold-spawns). */
export interface ParsedTermTile {
  termId: string | null;
  frame?: Rect;
  z: number;
}

/** A board doc placement parsed from a restored tile (shelf docs are split out
 * into `shelfPaths`). `frame` undefined ⇒ M1 scatter. */
export interface ParsedDocTile {
  path: string;
  frame?: Rect;
  z: number;
  attached: boolean;
}

export interface ParsedTiles {
  termTiles: ParsedTermTile[];
  docTiles: ParsedDocTile[];
  shelfPaths: string[];
}

/** Stacking order is a small index, but clamp to a safe integer range before it
 * becomes the wire's `i64` so a corrupt/huge `z` can never silently truncate. */
const Z_LIMIT = 2_000_000_000;
function intZ(z: number): number {
  const r = Math.round(z);
  return r > Z_LIMIT ? Z_LIMIT : r < -Z_LIMIT ? -Z_LIMIT : r;
}

/**
 * Build the persisted `tiles[]` from the live board: surviving terminal tiles
 * first (dead excluded), then board doc tiles sorted by path (deterministic
 * order, matching Swift), then shelf doc tiles (no geometry). `z` is rounded to
 * an integer so it deserializes into the wire's `i64`.
 */
export function buildTiles(
  terms: TermTileInput[],
  docs: DocTileInput[],
  shelfPaths: string[],
): LayoutTile[] {
  const tiles: LayoutTile[] = [];

  for (const t of terms) {
    if (t.dead) continue;
    tiles.push({
      kind: "term",
      x: t.frame.x,
      y: t.frame.y,
      w: t.frame.w,
      h: t.frame.h,
      z: intZ(t.z),
      term_id: t.termId,
    });
  }

  const sortedDocs = [...docs].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  for (const d of sortedDocs) {
    tiles.push({
      kind: "doc",
      path: d.path,
      x: d.frame.x,
      y: d.frame.y,
      w: d.frame.w,
      h: d.frame.h,
      z: intZ(d.z),
      loose: !d.attached,
    });
  }

  for (const path of shelfPaths) {
    tiles.push({ kind: "doc", path, shelf: true, loose: true });
  }

  return tiles;
}

/** True when all four geometry keys are present (a tile that can be placed). The
 * `!= null` guards treat a wire `null` like a missing key (serde omits None, but
 * a defensive null must not be read as a 0 coordinate). */
function hasGeometry(t: LayoutTile): boolean {
  return t.x != null && t.y != null && t.w != null && t.h != null;
}

function frameOf(t: LayoutTile): Rect | undefined {
  return hasGeometry(t) ? { x: t.x!, y: t.y!, w: t.w!, h: t.h! } : undefined;
}

/**
 * Parse a restored `tiles[]` into term / board-doc / shelf placements. Unknown
 * `kind`s are skipped (receiver rule). A doc tile with `shelf:true` goes to
 * `shelfPaths` (chip, never a card); otherwise it's a board doc with
 * `attached = !loose`. `z` defaults to 0.
 */
export function parseTiles(tiles: LayoutTile[]): ParsedTiles {
  const termTiles: ParsedTermTile[] = [];
  const docTiles: ParsedDocTile[] = [];
  const shelfPaths: string[] = [];

  for (const t of tiles) {
    if (t.kind === "term") {
      termTiles.push({ termId: t.term_id ?? null, frame: frameOf(t), z: t.z ?? 0 });
    } else if (t.kind === "doc") {
      if (t.path === undefined) continue; // a doc tile without a path is unplaceable
      if (t.shelf === true) {
        shelfPaths.push(t.path);
      } else {
        docTiles.push({
          path: t.path,
          frame: frameOf(t),
          z: t.z ?? 0,
          attached: t.loose !== true,
        });
      }
    }
    // unknown kinds: skipped
  }

  return { termTiles, docTiles, shelfPaths };
}
