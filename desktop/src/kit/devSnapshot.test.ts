import { describe, it, expect } from "vitest";
import {
  buildSnapshot,
  boardRectToScreenRect,
  scrollbackTail,
  tailWindowBounds,
  bareCardId,
} from "./devSnapshot";
import { cardId } from "../board/model";
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
  quitGuard: null as Parameters<typeof buildSnapshot>[0]["quitGuard"],
  borrowedId: null as string | null,
  ...over,
});

describe("S1 — the snapshot's shape", () => {
  it("carries exactly the documented top-level keys", () => {
    const snap = buildSnapshot(input());
    expect(Object.keys(snap).sort()).toEqual(
      [
        "active_element",
        "board_id",
        "cards",
        "focused_card",
        "quit_guard",
        "v",
        "viewport",
        "visibility",
      ].sort(),
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

describe("S3 — screen_rect is the measurement, or null", () => {
  it("reports screen_rect null and keeps its board_rect when nothing measured it", () => {
    const snap = buildSnapshot(input());
    expect(snap.cards[0].screen_rect).toBeNull();
    expect(snap.cards[0].board_rect).toEqual({ x: 10, y: 20, w: 400, h: 300 });
  });

  it("reports the MEASURED rect, not the projection of the board rect", () => {
    // The two deliberately disagree. Reporting the projection here would make
    // D1 — "the painted position matches the projection within ±1px" — compare
    // the projection with itself and pass for any card, anywhere.
    const measured = { x: 999, y: 888, w: 77, h: 66 };
    const snap = buildSnapshot(input({ screenRects: new Map([["term:t-1", measured]]) }));
    expect(snap.cards[0].screen_rect).toEqual(measured);
    const projected = boardRectToScreenRect(snap.cards[0].board_rect, snap.viewport, VIEW);
    expect(snap.cards[0].screen_rect).not.toEqual(projected);
  });

  it("reports a zero-size measurement as measured, not as absent", () => {
    // S3's "never {0,0,0,0}" is about an absent NODE. A node that measured zero
    // is an observation and must survive as one.
    const zero = { x: 12, y: 34, w: 0, h: 0 };
    const snap = buildSnapshot(input({ screenRects: new Map([["term:t-1", zero]]) }));
    expect(snap.cards[0].screen_rect).toEqual(zero);
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

describe("S4 — the caller may pass the window instead of the whole buffer", () => {
  const lines = (n: number) => Array.from({ length: n }, (_, i) => `line ${i + 1}`);

  it("gives the same answer from the window as from the whole buffer", () => {
    // The shell reads only `tailWindowBounds` rows off xterm — a terminal holds
    // 5000 lines of scrollback and reports 40 — so `scrollbackTail` must be
    // indifferent to which of the two it is handed, with `cursorLine` absolute
    // either way. Nothing else pins that, and it is what the windowed read rests
    // on: get it wrong and every `contains` assertion silently reads the wrong
    // rows.
    for (const [len, cursor] of [
      [5000, 4999],
      [5000, 2500],
      [120, 99],
      [50, 4],
      [3, 2],
      [1, 0],
    ] as const) {
      const buffer = lines(len);
      const { start, end } = tailWindowBounds(cursor, buffer.length);
      const window = buffer.slice(start, end + 1);
      expect(scrollbackTail(window, cursor)).toBe(scrollbackTail(buffer, cursor));
    }
  });

  it("never asks for more rows than the tail keeps", () => {
    const { start, end } = tailWindowBounds(4999, 5000);
    expect(end - start + 1).toBe(40);
  });
});

describe("S5 — absent facts are null, never empty strings", () => {
  const withSelection = (selection: string | null) =>
    buildSnapshot(
      input({ cards: [term({ term: { cols: 80, rows: 24, proc: null, selection, lines: [], cursorLine: 0 } })] }),
    ).cards[0].term!;

  it("reports no proc as null", () => {
    expect(withSelection(null).proc).toBeNull();
  });

  it("normalises xterm's empty-string selection to null", () => {
    // xterm returns "" for no selection, and "" would make `contains ""` match
    // vacuously — so the driver must not pass it through. This is the assertion
    // that fails if the normalisation moves back out into the untested shell.
    expect(withSelection("").selection).toBeNull();
    expect(withSelection(null).selection).toBeNull();
    expect(withSelection("hi").selection).toBe("hi");
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

  it("strips both prefixes and leaves anything else alone", () => {
    expect(bareCardId("term:t-1")).toBe("t-1");
    expect(bareCardId("doc:/a/b.md")).toBe("/a/b.md");
    expect(bareCardId("t-1")).toBe("t-1");
  });

  it("is the exact inverse of the app's own cardId()", () => {
    // The prefix convention is declared in board/model.ts and undone here. The
    // kit layering forbids importing that at runtime, so nothing but this test
    // ties the two together — without it they drift silently and every wire id
    // the driver reports goes wrong at once. (A kit TEST importing board/ is the
    // sanctioned shape; kit/zOrder.test.ts does the same, docs/coding-style.md.)
    const term = { kind: "term", termId: "t-1" } as Parameters<typeof cardId>[0];
    const doc = { kind: "doc", path: "/Users/e/a.b.md" } as Parameters<typeof cardId>[0];
    expect(bareCardId(cardId(term))).toBe("t-1");
    expect(bareCardId(cardId(doc))).toBe("/Users/e/a.b.md");
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

const guard = (over = {}) => ({
  retargeted: true,
  enabled: true,
  phase: "showing" as const,
  notice: { visible: true, alpha: 0.5 },
  last_press: { press_ms: 5, route: "guard" as const, age_ms: 3 },
  ...over,
});

describe("S35 — the quit guard's own facts ride along", () => {
  it("copies quitGuard verbatim", () => {
    const snap = buildSnapshot(input({ quitGuard: guard() }));
    expect(snap.quit_guard).toEqual(guard());
  });

  it("reports null when the backend could not answer", () => {
    // Not `undefined`: `--until` reads a missing path as unresolvable, and an
    // absent key would make `quit_guard.retargeted == true` a silent false.
    expect(buildSnapshot(input({ quitGuard: null })).quit_guard).toBeNull();
  });
});

describe("S5 (2609.0018) — a hidden notice reads alpha 0", () => {
  it("copies a visible notice as is", () => {
    expect(buildSnapshot(input({ quitGuard: guard() })).quit_guard).toEqual({
      retargeted: true,
      enabled: true,
      phase: "showing",
      notice: { visible: true, alpha: 0.5 },
      last_press: { press_ms: 5, route: "guard", age_ms: 3 },
    });
  });

  it("zeroes alpha when the panel is not visible", () => {
    // `hide_notice` resets a hidden panel's alphaValue to 1.0, which would read
    // as a notice at full opacity.
    const snap = buildSnapshot(
      input({ quitGuard: guard({ phase: "idle", notice: { visible: false, alpha: 1 } }) }),
    );
    expect(snap.quit_guard?.notice).toEqual({ visible: false, alpha: 0 });
  });

  it("keeps a visible notice's alpha while the guard is already idle", () => {
    // After a tap's release the guard is Idle while the notice still lingers
    // and fades: `visible` is the discriminator, never `phase`.
    const snap = buildSnapshot(
      input({ quitGuard: guard({ phase: "idle", notice: { visible: true, alpha: 0.3 } }) }),
    );
    expect(snap.quit_guard?.notice).toEqual({ visible: true, alpha: 0.3 });
  });
});

describe("S9 (2609.0018) — borrowed is a doc card's fact", () => {
  const cards = () => [
    doc({ id: "doc:/a/c.html" }),
    doc({ id: "doc:/a/b.md" }),
    term(),
  ];
  const byId = (snap: ReturnType<typeof buildSnapshot>, id: string) =>
    snap.cards.find((c) => c.id === id)!;

  it("is true only for the borrowed card, and absent from a terminal", () => {
    const snap = buildSnapshot(input({ cards: cards(), borrowedId: "doc:/a/c.html" }));
    expect(byId(snap, "/a/c.html").borrowed).toBe(true);
    expect(byId(snap, "/a/b.md").borrowed).toBe(false);
    expect("borrowed" in byId(snap, "t-1")).toBe(false);
  });

  it("is false on every doc card when nothing is borrowed", () => {
    const snap = buildSnapshot(input({ cards: cards(), borrowedId: null }));
    expect(byId(snap, "/a/c.html").borrowed).toBe(false);
    expect(byId(snap, "/a/b.md").borrowed).toBe(false);
  });
});
