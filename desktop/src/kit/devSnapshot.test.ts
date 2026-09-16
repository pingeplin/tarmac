import { describe, it, expect } from "vitest";
import { buildSnapshot, boardRectToScreenRect, scrollbackTail, bareCardId, internalCardId } from "./devSnapshot";
import { worldToView } from "./boardTransform";
import type { Rect } from "./geom";

// This file runs in Vitest's default `node` environment (desktop/vitest.config.ts),
// so there is no `document`. A builder that reached for one would throw rather
// than pass — the purity rule is enforced by the environment, not by inspection.

const VIEW: Rect = { x: 24, y: 40, w: 1000, h: 700 };

const term = (over: Partial<Parameters<typeof buildSnapshot>[0]["cards"][number]> = {}) => ({
  id: "term:t-1",
  kind: "term" as const,
  frame: { x: 10, y: 20, w: 400, h: 300 },
  live: true,
  dead: false,
  term: { cols: 80, rows: 24, proc: "zsh", selection: null, lines: ["hi"], cursorLine: 0 },
  ...over,
});

const doc = (over = {}) => ({
  id: "doc:/Users/e/a.b.md",
  kind: "doc" as const,
  frame: { x: 500, y: 20, w: 300, h: 200 },
  ...over,
});

const input = (over = {}) => ({
  boardId: "board-0",
  visibilityState: "visible" as const,
  viewport: { zoom: 1, cx: 500, cy: 350 },
  viewRect: VIEW,
  cards: [term(), doc()],
  screenRects: new Map<string, Rect>(),
  selectedId: null as string | null,
  activeElement: { card: null, tag: "BODY", classes: [], selectionType: "None" as const },
  ...over,
});

describe("S1 — the snapshot's shape", () => {
  it("carries exactly the documented top-level keys", () => {
    const snap = buildSnapshot(input());
    expect(Object.keys(snap).sort()).toEqual(
      ["active_element", "board_id", "cards", "focused_card", "v", "viewport", "visibility"].sort(),
    );
    expect(snap.v).toBe(1);
    expect(snap.board_id).toBe("board-0");
    expect(Object.keys(snap.viewport).sort()).toEqual(["cx", "cy", "view_rect", "zoom"]);
    expect(snap.viewport.view_rect).toEqual(VIEW);
  });
});

describe("S2 — a doc card has no `term` key at all", () => {
  it("omits the key rather than setting it undefined", () => {
    const snap = buildSnapshot(input());
    const [t, d] = snap.cards;
    expect(Object.keys(t.term!).sort()).toEqual(
      ["alive", "cols", "proc", "rows", "scrollback_tail", "selection"].sort(),
    );
    // `term: undefined` would survive JSON.stringify by vanishing, but `--until`
    // would read it as a silent false rather than an unresolvable path.
    expect("term" in d).toBe(false);
    expect(JSON.parse(JSON.stringify(snap)).cards[1]).not.toHaveProperty("term");
  });
});

describe("S3 — an unmeasured card", () => {
  it("reports screen_rect null and keeps its board_rect", () => {
    const snap = buildSnapshot(input());
    expect(snap.cards[0].screen_rect).toBeNull();
    expect(snap.cards[0].board_rect).toEqual({ x: 10, y: 20, w: 400, h: 300 });
  });
});

describe("S4 — scrollback_tail ends at the cursor row", () => {
  const lines = (n: number) => Array.from({ length: n }, (_, i) => `line ${i + 1}`);

  it("is the 40 lines ending at the cursor", () => {
    expect(scrollbackTail(lines(120), 99).split("\n")).toEqual(lines(100).slice(60));
  });

  it("is short, not padded, when the cursor is near the top", () => {
    expect(scrollbackTail(lines(120), 4).split("\n")).toEqual(lines(5));
  });

  it("ignores the blank rows below the cursor", () => {
    // A 50-row buffer, output on the first 5 lines, cursor on line 5. Taking
    // "the last 40 lines of buffer.active" returns 40 blanks here — it passes
    // both cases above and breaks every `contains` assertion in D3-D6.
    const buffer = [...lines(5), ...Array.from({ length: 45 }, () => "")];
    expect(scrollbackTail(buffer, 4).split("\n")).toEqual(lines(5));
  });
});

describe("S5 — absent facts are null, never empty strings", () => {
  it("reports no proc and no selection as null", () => {
    const snap = buildSnapshot(
      input({ cards: [term({ term: { cols: 80, rows: 24, proc: null, selection: null, lines: [], cursorLine: 0 } })] }),
    );
    expect(snap.cards[0].term!.proc).toBeNull();
    // "" would make `contains ""` match vacuously.
    expect(snap.cards[0].term!.selection).toBeNull();
  });
});

describe("S6 — the active board only", () => {
  it("never reports a card the caller did not pass", () => {
    const snap = buildSnapshot(input({ cards: [term()] }));
    expect(snap.cards.map((c) => c.id)).toEqual(["t-1"]);
  });
});

describe("S74 — visibility is reported, not assumed", () => {
  it("carries the supplied visibilityState", () => {
    expect(buildSnapshot(input({ visibilityState: "hidden" })).visibility).toBe("hidden");
    expect(buildSnapshot(input({ visibilityState: "visible" })).visibility).toBe("visible");
  });
});

describe("S75 — term.alive is live && !dead", () => {
  it("reports a held-open dead card as not alive", () => {
    const alive = (live: boolean, dead: boolean) =>
      buildSnapshot(input({ cards: [term({ live, dead })] })).cards[0].term!.alive;
    expect(alive(true, false)).toBe(true);
    // A dead card still renders and accepts focus, then swallows every `type`.
    expect(alive(true, true)).toBe(false);
    expect(alive(false, false)).toBe(false);
  });
});

describe("S76 — ids on the wire are bare, ids inside the app are prefixed", () => {
  it("strips the prefix for the snapshot", () => {
    const snap = buildSnapshot(input({ selectedId: "term:t-1" }));
    expect(snap.cards.map((c) => c.id)).toEqual(["t-1", "/Users/e/a.b.md"]);
    expect(snap.focused_card).toBe("t-1");
    expect(snap.cards[0].focused).toBe(true);
    expect(snap.cards[1].focused).toBe(false);
  });

  it("maps a bare id back to the internal one, and refuses a prefixed one", () => {
    const cards = input().cards;
    expect(internalCardId("t-1", cards)).toBe("term:t-1");
    expect(internalCardId("/Users/e/a.b.md", cards)).toBe("doc:/Users/e/a.b.md");
    // `tarmac dev focus term:t-1` is not the CLI's contract, and accepting it
    // would hide an implementation that never strips at all.
    expect(internalCardId("term:t-1", cards)).toBeNull();
    expect(internalCardId("t-9", cards)).toBeNull();
  });

  it("strips both prefixes and leaves anything else alone", () => {
    expect(bareCardId("term:t-1")).toBe("t-1");
    expect(bareCardId("doc:/a/b.md")).toBe("/a/b.md");
    expect(bareCardId("t-1")).toBe("t-1");
  });
});

describe("S7 — the projection agrees with the board transform", () => {
  const project = (zoom: number, r: Rect, view: Rect, cx: number, cy: number) =>
    boardRectToScreenRect(r, { zoom, cx, cy }, view);

  it("matches worldToView at both corners, at a non-zero view origin", () => {
    const r: Rect = { x: 120, y: 60, w: 200, h: 100 };
    const centre = { x: VIEW.x + VIEW.w / 2, y: VIEW.y + VIEW.h / 2 };
    for (const zoom of [0.5, 1, 2.37]) {
      const got = project(zoom, r, VIEW, 500, 350);
      const tl = worldToView({ x: r.x, y: r.y }, zoom, { x: 500, y: 350 }, centre);
      const br = worldToView({ x: r.x + r.w, y: r.y + r.h }, zoom, { x: 500, y: 350 }, centre);
      expect(got.x).toBeCloseTo(tl.x, 9);
      expect(got.y).toBeCloseTo(tl.y, 9);
      expect(got.w).toBeCloseTo(br.x - tl.x, 9);
      expect(got.h).toBeCloseTo(br.y - tl.y, 9);
    }
  });

  it("matches a hand-computed literal", () => {
    // Independent of worldToView, so a shared convention error cannot hide here.
    // view centre = (24 + 500, 40 + 350) = (524, 390); zoom 2.
    // x = (120 - 500)*2 + 524 = -236 ;  y = (60 - 350)*2 + 390 = -190
    // w = 200*2 = 400 ;  h = 100*2 = 200
    const got = project(2, { x: 120, y: 60, w: 200, h: 100 }, VIEW, 500, 350);
    expect(got).toEqual({ x: -236, y: -190, w: 400, h: 200 });
  });
});

describe("S8 — zoom scales the size, not only the origin", () => {
  const r: Rect = { x: 100, y: 50, w: 200, h: 120 };

  it("at zoom 1 is a pure translation by the view origin", () => {
    const got = boardRectToScreenRect(r, { zoom: 1, cx: VIEW.w / 2, cy: VIEW.h / 2 }, VIEW);
    expect(got).toEqual({ x: r.x + VIEW.x, y: r.y + VIEW.y, w: r.w, h: r.h });
  });

  it("at zoom 2.37 scales w and h", () => {
    // The load-bearing row: at zoom 1, w and w*zoom are identical, so copying
    // the size straight through passes the case above.
    const got = boardRectToScreenRect(r, { zoom: 2.37, cx: VIEW.w / 2, cy: VIEW.h / 2 }, VIEW);
    expect(got.w).toBeCloseTo(474, 9);
    expect(got.h).toBeCloseTo(284.4, 9);
  });
});
