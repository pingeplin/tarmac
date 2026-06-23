import { describe, it, expect } from "vitest";
import {
  rows,
  boardIdForOrdinal,
  clampSelection,
  canDelete,
  sanitizedName,
  isTypable,
  liveness,
  meta,
  type BoardSummary,
} from "./boardSwitcher";

// Port of BoardSwitcherTests.swift (M3 P4): the ⌘K switcher view-model — prefix
// filter, ⌘1..9 ordinal on the *visible* rows, selection clamp, meta-line
// formatting, plus P5 liveness and P5.4 rename/delete validation.

// Helper mirroring the Swift `sum(...)` defaults (running/bell/cards = 0,
// isLive = true, name = null).
function sum(
  id: string,
  opts: Partial<Omit<BoardSummary, "boardID">> = {},
): BoardSummary {
  return {
    boardID: id,
    name: opts.name ?? null,
    running: opts.running ?? 0,
    bell: opts.bell ?? 0,
    cards: opts.cards ?? 0,
    isLive: opts.isLive ?? true,
  };
}

const three: BoardSummary[] = [
  { boardID: "board-0", name: "infra-week", running: 2, bell: 1, cards: 8, isLive: true },
  { boardID: "board-1", name: "exp-search", running: 1, bell: 0, cards: 3, isLive: true },
  { boardID: "board-2", name: null, running: 0, bell: 0, cards: 0, isLive: false },
];

describe("BoardSwitcher", () => {
  // --- liveness() (P5: honest per-board liveness) ---

  it("visited board uses local signals not daemon count", () => {
    // A board the app has visited: local card signals are authoritative, so the
    // daemon's count is ignored (no flicker against the local view).
    const r = liveness(true, 2, true, 0);
    expect(r.running).toBe(2);
    expect(r.isLive).toBe(true);
  });

  it("visited board with no local live is not live", () => {
    // A visited board's own (dead) sessions win over a stale daemon count.
    const r = liveness(true, 0, false, 5);
    expect(r.running).toBe(0);
    expect(r.isLive).toBe(false);
  });

  it("never-visited board uses daemon running for liveness", () => {
    // The relaunch case: shells survived, the app hasn't visited the board, so
    // the daemon's live-pty count is the only honest source.
    const r = liveness(false, 0, false, 3);
    expect(r.running).toBe(3);
    expect(r.isLive).toBe(true);
  });

  it("never-visited board with zero daemon running is faint", () => {
    const r = liveness(false, 0, false, 0);
    expect(r.running).toBe(0);
    expect(r.isLive).toBe(false);
  });

  it("never-visited board with null daemon running is faint", () => {
    // A pre-P5 daemon (or no report) → null → treated as zero live.
    const r = liveness(false, 0, false, null);
    expect(r.running).toBe(0);
    expect(r.isLive).toBe(false);
  });

  // --- rows() ---

  it("empty filter keeps all in order", () => {
    const result = rows(three, "board-1", "");
    expect(result.map((r) => r.boardID)).toEqual(["board-0", "board-1", "board-2"]);
  });

  it("active flag marks the active board", () => {
    const result = rows(three, "board-1", "");
    expect(result.map((r) => r.isActive)).toEqual([false, true, false]);
  });

  it("unnamed board falls back to slug", () => {
    const result = rows(three, "board-0", "");
    expect(result[2].display).toBe("board-2");
  });

  it("filter is case-insensitive prefix on display", () => {
    const result = rows(three, "board-0", "EXP");
    expect(result.map((r) => r.boardID)).toEqual(["board-1"]);
  });

  it("filter matches slug for unnamed boards", () => {
    // "board-2" has no name → its display is the slug, so the slug filters it.
    const result = rows(three, "board-0", "board-2");
    expect(result.map((r) => r.boardID)).toEqual(["board-2"]);
  });

  it("prefix does not match mid-string", () => {
    // "week" is a substring of "infra-week" but not a prefix → no match.
    const result = rows(three, "board-0", "week");
    expect(result).toEqual([]);
  });

  it("row carries glyph and count inputs", () => {
    const result = rows(three, "board-0", "infra");
    const r = result[0];
    expect(r.isLive).toBe(true);
    expect(r.running).toBe(2);
    expect(r.bell).toBe(1);
    expect(r.cards).toBe(8);
    expect(r.meta).toBe("2 running · 1 bell · 8 cards");
  });

  // --- boardIdForOrdinal(n, rows) ---

  it("ordinal is one-based on visible rows", () => {
    const result = rows(three, "board-0", "");
    expect(boardIdForOrdinal(1, result)).toBe("board-0");
    expect(boardIdForOrdinal(3, result)).toBe("board-2");
  });

  it("ordinal addresses filtered rows not full list", () => {
    // After filtering to a single row, ⌘1 must hit that visible row.
    const result = rows(three, "board-0", "exp");
    expect(boardIdForOrdinal(1, result)).toBe("board-1");
    expect(boardIdForOrdinal(2, result)).toBeUndefined();
  });

  it("ordinal out of range is undefined", () => {
    const result = rows(three, "board-0", "");
    expect(boardIdForOrdinal(0, result)).toBeUndefined();
    expect(boardIdForOrdinal(4, result)).toBeUndefined();
  });

  // --- clampSelection ---

  it("clamp selection bounds", () => {
    expect(clampSelection(-3, 3)).toBe(0);
    expect(clampSelection(1, 3)).toBe(1);
    expect(clampSelection(9, 3)).toBe(2);
    expect(clampSelection(0, 0)).toBe(0); // empty list pins to 0
  });

  // --- meta() ---

  it("meta all segments", () => {
    expect(meta(2, 1, 8)).toBe("2 running · 1 bell · 8 cards");
  });

  it("meta drops zero running and bell", () => {
    expect(meta(0, 0, 3)).toBe("3 cards");
    expect(meta(1, 0, 3)).toBe("1 running · 3 cards");
  });

  it("meta singular card", () => {
    expect(meta(0, 0, 1)).toBe("1 card");
  });

  it("meta cards always shown even at zero", () => {
    expect(meta(0, 0, 0)).toBe("0 cards");
  });

  // --- P5.4 rename / delete validation ---

  it("can delete only when more than one", () => {
    expect(canDelete(2)).toBe(true);
    expect(canDelete(1)).toBe(false); // the last board can't be deleted
    expect(canDelete(0)).toBe(false);
  });

  it("sanitized name trims and blanks to empty", () => {
    expect(sanitizedName("  infra  ")).toBe("infra");
    expect(sanitizedName("infra")).toBe("infra");
    expect(sanitizedName("   ")).toBe(""); // whitespace-only clears the name
    expect(sanitizedName("")).toBe("");
  });

  it("isTypable accepts printables, rejects control and function keys", () => {
    expect(isTypable("a".codePointAt(0)!)).toBe(true);
    expect(isTypable(0x20)).toBe(true); // space is typable
    expect(isTypable("é".codePointAt(0)!)).toBe(true);
    expect(isTypable(0x1f)).toBe(false); // control char
    expect(isTypable(0x7f)).toBe(false); // DEL
    // AppKit function/arrow/nav keys (private-use 0xF700–0xF8FF) are rejected.
    expect(isTypable(0xf700)).toBe(false); // NSUpArrowFunctionKey
    expect(isTypable(0xf729)).toBe(false); // NSHomeFunctionKey
    expect(isTypable(0xf8ff)).toBe(false); // private-use top
  });
});

// `sum` helper is exercised here to keep parity with the Swift fixture builder
// (and to avoid an unused-symbol lint); it produces the same defaults.
describe("BoardSwitcher fixture helper", () => {
  it("sum applies Swift defaults", () => {
    expect(sum("b")).toEqual({
      boardID: "b",
      name: null,
      running: 0,
      bell: 0,
      cards: 0,
      isLive: true,
    });
  });
});
