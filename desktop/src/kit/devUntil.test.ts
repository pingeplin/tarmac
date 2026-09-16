import { describe, it, expect } from "vitest";
import { parseUntil, evalUntil, type UntilExpr } from "./devUntil";

const snap = {
  v: 1,
  viewport: { zoom: 0.5, cx: 0, cy: 0 },
  cards: [
    {
      id: "t-1",
      kind: "term",
      board_rect: { x: 0, y: 0, w: 800, h: 600 },
      focused: true,
      term: { cols: 80, rows: 24, proc: "sleep", selection: null, scrollback_tail: "say hi\nhi" },
    },
    { id: "/Users/e/a.b.md", kind: "doc", board_rect: { x: 0, y: 0, w: 1, h: 1 }, focused: false },
    { id: "/tmp/a]b.md", kind: "doc", board_rect: { x: 0, y: 0, w: 1, h: 1 }, focused: false },
  ],
  focused_card: "t-1",
};

/** Parse-and-evaluate, failing loudly if the expression did not parse. */
const holds = (src: string, against: unknown = snap): boolean => {
  const expr = parseUntil(src);
  if ("error" in expr) throw new Error(`expected ${src} to parse, got ${expr.error}`);
  return evalUntil(expr as UntilExpr, against);
};

describe("S25 — ==", () => {
  it("compares a number at a dotted path", () => {
    expect(holds("viewport.zoom == 0.5")).toBe(true);
    expect(holds("viewport.zoom == 0.5", { ...snap, viewport: { zoom: 1 } })).toBe(false);
  });
});

describe("S26 — ~= is |Δ| ≤ 1", () => {
  const at = (w: number) =>
    holds("cards[t-1].board_rect.w ~= 800", {
      ...snap,
      cards: [{ ...snap.cards[0], board_rect: { x: 0, y: 0, w, h: 600 } }],
    });

  it("accepts a delta of exactly 1 in both directions", () => {
    // The load-bearing rows: at |Δ| = 1 a `< 1` implementation says false.
    expect(at(799)).toBe(true);
    expect(at(801)).toBe(true);
  });

  it("accepts inside the band and rejects outside it", () => {
    expect(at(799.4)).toBe(true);
    expect(at(800.9)).toBe(true);
    expect(at(798.9)).toBe(false);
    // Rules out a `<= 2` band.
    expect(at(801.5)).toBe(false);
  });
});

describe("S27/S28 — a bracketed card id is literal", () => {
  it("resolves an id containing dots and slashes", () => {
    // A naive split on "." would look for a `cards[/Users/e/a` card.
    expect(holds('cards[/Users/e/a.b.md].focused == true')).toBe(false);
    expect(holds('cards[/Users/e/a.b.md].kind == "doc"')).toBe(true);
  });

  it("runs the id to the LAST `]`, so an id may contain one", () => {
    expect(holds('cards[/tmp/a]b.md].kind == "doc"')).toBe(true);
  });
});

describe("S29 — contains", () => {
  it("is a substring test on a string", () => {
    expect(holds('cards[t-1].term.scrollback_tail contains "hi"')).toBe(true);
    expect(holds('cards[t-1].term.scrollback_tail contains "nope"')).toBe(false);
  });
});

describe("S30 — !=", () => {
  it("works against a string and against null", () => {
    expect(holds('cards[t-1].term.proc != "sleep"')).toBe(false);
    expect(holds("cards[t-1].term.proc != null")).toBe(true);
    expect(holds("cards[t-1].term.selection != null")).toBe(false);
  });
});

describe("S31 — an unresolvable path is false, not an error", () => {
  it("keeps polling for a card that has not rendered yet", () => {
    expect(holds("cards[t-9].term.cols == 80")).toBe(false);
    expect(holds("viewport.nope == 1")).toBe(false);
    expect(holds("cards[/Users/e/a.b.md].term.cols == 80")).toBe(false);
    // ...and `!=` against a missing path is false too: a path that does not
    // resolve makes no claim either way, so neither polarity may fire.
    expect(holds("cards[t-9].term.cols != 80")).toBe(false);
  });
});

describe("S32 — contains on a non-string", () => {
  it("is false and does not throw", () => {
    expect(holds('viewport.zoom contains "0"')).toBe(false);
    expect(holds('cards[t-1].term.selection contains "x"')).toBe(false);
  });
});

describe("S33 — a malformed expression is a parse error, not false", () => {
  it("is distinguishable from an expression that simply does not hold", () => {
    for (const bad of ["viewport.zoom =! 0.5", 'cards[t-1].kind == "unterminated', "", "   ", "viewport.zoom", "== 1"]) {
      const parsed = parseUntil(bad);
      expect("error" in parsed, `expected a parse error for ${JSON.stringify(bad)}`).toBe(true);
    }
    // ...and a well-formed one is not.
    expect("error" in parseUntil("viewport.zoom == 1")).toBe(false);
  });
});

describe("S34 — value literals", () => {
  it("parses each type", () => {
    const value = (src: string) => {
      const p = parseUntil(`x == ${src}`);
      if ("error" in p) throw new Error(`${src} did not parse: ${p.error}`);
      return (p as UntilExpr).value;
    };
    expect(value("0.5")).toBe(0.5);
    expect(value("-1")).toBe(-1);
    expect(value('"a \\"quoted\\" \\\\ path"')).toBe('a "quoted" \\ path');
    expect(value("null")).toBeNull();
    expect(value("true")).toBe(true);
    expect(value("false")).toBe(false);
  });
});
