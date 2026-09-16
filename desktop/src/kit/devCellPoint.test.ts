import { describe, it, expect } from "vitest";
import { devCellPoint } from "./devCellPoint";

// The grid the card holds, and the rect xterm's screen element occupies.
const COLS = 80;
const ROWS = 20;
// What `Element.prototype.getBoundingClientRect.call(term.screenElement)` returns
// — the UNPATCHED rect.
const UNPATCHED = { x: 100, y: 50, w: 640, h: 320 };
// What `term.screenElement.getBoundingClientRect()` returns instead, because
// TerminalCard patches it: at rasterScale 2 with a stale anchor of 0,
// `left' = last − (last − r.left)/s = −(0 − 100)/2 = 50` and `width' = r.w/s = 320`.
const PATCHED = { x: 50, y: 25, w: 320, h: 160 };

const viewport = (lines: string[]) =>
  Array.from({ length: ROWS }, (_, i) => lines[i] ?? "");

describe("S17 — the point is the centre of the last written cell", () => {
  // The last non-empty row is index 7 and holds 9 non-blank cells, so the target
  // cell is (8, 7) — the last cell that has a character in it.
  const lines = viewport(["$ echo hi", "", "", "", "", "", "", "123456789"]);

  it("is the exact cell centre, not a range", () => {
    // An off-by-one in either axis lands in a neighbouring cell, so this asserts
    // the centre exactly.
    expect(devCellPoint({ lines, screenRect: UNPATCHED, cols: COLS })).toEqual({
      x: UNPATCHED.x + 8.5 * (UNPATCHED.w / COLS),
      y: UNPATCHED.y + 7.5 * (UNPATCHED.h / ROWS),
    });
  });

  it("is computed from the UNPATCHED rect — that is the algebra, not an oversight", () => {
    // The algebra is in the module header; this pins its consequence — the two
    // rects give different points, and the contract is that the caller passes the
    // unpatched one. Note what this test CANNOT do: the rect arrives by argument,
    // so it never sees which one `devDriver` actually passes, and no scenario at
    // any tier can tell either (measured at seven zooms — #174). The caller's
    // `Element.prototype` call stands on the algebra, not on this test.
    const fromPatched = PATCHED.x + 8.5 * (PATCHED.w / COLS);
    const point = devCellPoint({ lines, screenRect: UNPATCHED, cols: COLS });
    expect(point).not.toEqual(expect.objectContaining({ x: fromPatched }));
    expect(devCellPoint({ lines, screenRect: PATCHED, cols: COLS })).toEqual({
      x: fromPatched,
      y: PATCHED.y + 7.5 * (PATCHED.h / ROWS),
    });
  });

  it("ignores trailing blank rows below the last written one", () => {
    const trailing = viewport(["abc", "", "", "", "", "", "", "123456789", "", ""]);
    expect(devCellPoint({ lines: trailing, screenRect: UNPATCHED, cols: COLS })).toEqual(
      devCellPoint({ lines, screenRect: UNPATCHED, cols: COLS }),
    );
  });
});

describe("S18 — an empty buffer has no cell to right-click", () => {
  it("refuses rather than pointing at blank space", () => {
    // A right-click on blank space produces a Caret, not a Range, which would
    // silently downgrade D5 into a second copy of D4.
    expect(devCellPoint({ lines: viewport([]), screenRect: UNPATCHED, cols: COLS })).toMatchObject(
      { error: "empty_buffer" },
    );
    expect(
      devCellPoint({ lines: viewport(["   ", "\t"]), screenRect: UNPATCHED, cols: COLS }),
    ).toMatchObject({ error: "empty_buffer" });
  });
});
