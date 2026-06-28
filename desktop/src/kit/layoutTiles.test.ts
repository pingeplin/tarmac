// Tests for the board ↔ layout-tile codec: buildTiles (persist) + parseTiles
// (restore), and their round-trip — the contract that a board survives a restart.

import { describe, it, expect } from "vitest";
import {
  buildTiles,
  parseTiles,
  type TermTileInput,
  type DocTileInput,
  type LayoutTile,
} from "./layoutTiles";

const term = (termId: string, x: number, dead = false): TermTileInput => ({
  termId,
  frame: { x, y: 80, w: 470, h: 330 },
  z: 0,
  dead,
});
const doc = (path: string, x: number, attached = true): DocTileInput => ({
  path,
  frame: { x, y: 80, w: 392, h: 310 },
  z: 1,
  attached,
});

describe("buildTiles", () => {
  it("emits term tiles with term_id + integer z, excludes dead terminals", () => {
    const tiles = buildTiles([term("t1", 80), term("t2", 600, true)], []);
    expect(tiles).toHaveLength(1);
    expect(tiles[0]).toMatchObject({ kind: "term", term_id: "t1", x: 80, z: 0 });
    expect(tiles[0]).not.toHaveProperty("path");
  });

  it("rounds z to an integer (wire i64)", () => {
    const tiles = buildTiles([{ termId: "t1", frame: { x: 0, y: 0, w: 1, h: 1 }, z: 2.7, dead: false }], []);
    expect(tiles[0]!.z).toBe(3);
  });

  it("clamps a corrupt out-of-range z so it can't truncate as i64", () => {
    const tiles = buildTiles(
      [{ termId: "t1", frame: { x: 0, y: 0, w: 1, h: 1 }, z: 1.7e308, dead: false }],
      [],
    );
    expect(Number.isSafeInteger(tiles[0]!.z!)).toBe(true);
    expect(tiles[0]!.z).toBe(2_000_000_000);
  });

  it("emits board doc tiles with loose = !attached, sorted by path", () => {
    const tiles = buildTiles([], [doc("/b.md", 600), doc("/a.md", 600, false)]);
    const docTiles = tiles.filter((t) => t.kind === "doc");
    expect(docTiles.map((t) => t.path)).toEqual(["/a.md", "/b.md"]); // sorted
    expect(docTiles.find((t) => t.path === "/a.md")!.loose).toBe(true); // detached
    expect(docTiles.find((t) => t.path === "/b.md")!.loose).toBe(false); // attached
  });

  it("orders tiles: terms first, then board docs", () => {
    const tiles = buildTiles([term("t1", 80)], [doc("/d.md", 600)]);
    expect(tiles.map((t) => t.kind)).toEqual(["term", "doc"]);
  });

  it("never emits shelf:true tiles", () => {
    const tiles = buildTiles([term("t1", 80)], [doc("/d.md", 600)]);
    expect(tiles.every((t) => !t.shelf)).toBe(true);
  });
});

describe("parseTiles", () => {
  it("splits term and board-doc tiles", () => {
    const tiles: LayoutTile[] = [
      { kind: "term", term_id: "t1", x: 80, y: 80, w: 470, h: 330, z: 0 },
      { kind: "doc", path: "/a.md", x: 600, y: 80, w: 392, h: 310, z: 1, loose: false },
    ];
    const parsed = parseTiles(tiles);
    expect(parsed.termTiles).toEqual([
      { termId: "t1", frame: { x: 80, y: 80, w: 470, h: 330 }, z: 0 },
    ]);
    expect(parsed.docTiles).toEqual([
      { path: "/a.md", frame: { x: 600, y: 80, w: 392, h: 310 }, z: 1, attached: true },
    ]);
  });

  it("drops legacy shelf:true tiles silently", () => {
    const tiles: LayoutTile[] = [
      { kind: "doc", path: "/parked.md", shelf: true, loose: true },
    ];
    const parsed = parseTiles(tiles);
    expect(parsed.docTiles).toHaveLength(0);
  });

  it("treats a geometry-less tile as M1 (frame undefined) and a null term_id as legacy", () => {
    const parsed = parseTiles([
      { kind: "term" },
      { kind: "doc", path: "/m1.md" },
    ]);
    expect(parsed.termTiles[0]).toEqual({ termId: null, frame: undefined, z: 0 });
    expect(parsed.docTiles[0]).toEqual({ path: "/m1.md", frame: undefined, z: 0, attached: true });
  });

  it("treats a doc tile with loose:true as detached", () => {
    const parsed = parseTiles([{ kind: "doc", path: "/x.md", x: 0, y: 0, w: 1, h: 1, loose: true }]);
    expect(parsed.docTiles[0]!.attached).toBe(false);
  });

  it("skips unknown kinds and path-less doc tiles", () => {
    const parsed = parseTiles([
      { kind: "frame" },
      { kind: "doc" },
      { kind: "term", term_id: "t1" },
    ]);
    expect(parsed.termTiles).toHaveLength(1);
    expect(parsed.docTiles).toHaveLength(0);
  });
});

describe("round-trip buildTiles → parseTiles", () => {
  it("preserves term ids/frames and doc attachment", () => {
    const terms = [term("t1", 80), term("t2", 600)];
    const docs = [doc("/a.md", 1100, true), doc("/b.md", 1100, false)];
    const parsed = parseTiles(buildTiles(terms, docs));

    expect(parsed.termTiles.map((t) => t.termId)).toEqual(["t1", "t2"]);
    expect(parsed.termTiles[0]!.frame).toEqual(terms[0]!.frame);

    const a = parsed.docTiles.find((d) => d.path === "/a.md")!;
    const b = parsed.docTiles.find((d) => d.path === "/b.md")!;
    expect(a.attached).toBe(true);
    expect(b.attached).toBe(false);
    expect(a.frame).toEqual(docs[0]!.frame);
  });

  // S11: term tile z survives buildTiles → parseTiles
  it("S11: preserves z for a term tile", () => {
    const input: TermTileInput = { termId: "t1", frame: { x: 0, y: 0, w: 470, h: 330 }, z: 7, dead: false };
    const parsed = parseTiles(buildTiles([input], []));
    expect(parsed.termTiles[0]!.z).toBe(7);
  });

  // S12: doc tile z survives buildTiles → parseTiles
  it("S12: preserves z for a doc tile", () => {
    const input: DocTileInput = { path: "/c.md", frame: { x: 0, y: 0, w: 392, h: 310 }, z: 5, attached: true };
    const parsed = parseTiles(buildTiles([], [input]));
    expect(parsed.docTiles[0]!.z).toBe(5);
  });
});
