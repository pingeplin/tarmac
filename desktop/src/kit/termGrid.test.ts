import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  proposeGrid,
  clampGrid,
  cardBox,
  nextGrid,
  scrollbarReserve,
  CARD_BOX_EPSILON,
  type GridBox,
  type RestGrid,
} from "./termGrid";

/** The live card's numbers at rasterScale 1: .term-host padding 2/10/16, the
 *  14px scrollbar reserve FitAddon used, and the measured JetBrainsMono cell. */
const box = (over: Partial<GridBox> = {}): GridBox => ({
  boxH: 290,
  boxW: 720,
  padV: 18,
  padH: 20,
  scrollbar: 14,
  cellW: 9.5,
  cellH: 21,
  ...over,
});

describe("S1 — rows come from the content box, not the padding box", () => {
  it("a 290px box with 24px padding and a 21px cell holds 12 rows", () => {
    // Measuring the padding box (the FitAddon bug) gives floor(290/21) = 13,
    // and that 13th row is the one that falls out of the card.
    expect(proposeGrid(box())!.rows).toBe(12);
  });

  it("does not return the padding-box answer", () => {
    expect(proposeGrid(box())!.rows).not.toBe(13);
  });

  it("padding is what separates the two answers", () => {
    expect(proposeGrid(box({ padV: 0 }))!.rows).toBe(13);
  });
});

describe("S2 — cols subtract the horizontal padding and the scrollbar", () => {
  it("720px wide, 20px padding, 14px scrollbar, 9.5px cell → 72 cols", () => {
    expect(proposeGrid(box())!.cols).toBe(72);
  });

  it("with no scrollbar the same box holds 73", () => {
    // Catches a hard-coded 14px reserve: it would answer 72 here too.
    expect(proposeGrid(box({ scrollbar: 0 }))!.cols).toBe(73);
  });

  it("with no padding and no scrollbar it holds 75", () => {
    expect(proposeGrid(box({ padH: 0, scrollbar: 0 }))!.cols).toBe(75);
  });
});

describe("S3 — the proposed grid always fits, and is the largest that does", () => {
  // The invariant that makes clipping impossible, over a full cell period.
  // Both clauses are needed: "fits" alone is satisfied by a constant 1 row,
  // "largest" alone by ceil().
  for (let boxH = 300; boxH <= 341; boxH++) {
    it(`boxH ${boxH}: fills the content box without exceeding it`, () => {
      const b = box({ boxH });
      const { rows } = proposeGrid(b)!;
      const content = b.boxH - b.padV;
      expect(rows * b.cellH).toBeLessThanOrEqual(content);
      expect((rows + 1) * b.cellH).toBeGreaterThan(content);
    });
  }
});

describe("S4 — an exact multiple of the cell height proposes no extra row", () => {
  it("content of exactly 14 cells holds 14 rows, not 15", () => {
    // boxH − padV = 294 = 14 × 21. This is the height that clipped worst before
    // the fix: the padding-box answer is floor(312/21) = 14 rows starting 2px
    // down, ending 2px past the box.
    const { rows } = proposeGrid(box({ boxH: 312 }))!;
    expect(rows).toBe(14);
    expect(rows * 21).toBe(294);
  });
});

describe("S5 — a collapsed box still yields a usable grid", () => {
  it("a box smaller than one cell floors at 2 cols × 1 row", () => {
    expect(proposeGrid(box({ boxH: 30, boxW: 40 }))).toEqual({ cols: 2, rows: 1 });
  });

  it("padding larger than the box does not go negative", () => {
    expect(proposeGrid(box({ boxH: 10, boxW: 10 }))).toEqual({ cols: 2, rows: 1 });
  });
});

describe("S6 — the clamp yields on the axis that no longer fits", () => {
  it("rest 74×31, proposal 74×30 → 74×30", () => {
    // The measured regression: at rasterScale 2 the cell is ~1px taller per row
    // than a clean ×2, so a ≥31-row card no longer holds its rest grid.
    expect(clampGrid({ cols: 74, rows: 31 }, { cols: 74, rows: 30 })).toEqual({
      cols: 74,
      rows: 30,
    });
  });
});

describe("S7 — a zoom never takes the grid above the rest grid", () => {
  it("rest 70×28, proposal 74×30 → 70×28", () => {
    expect(clampGrid({ cols: 70, rows: 28 }, { cols: 74, rows: 30 })).toEqual({
      cols: 70,
      rows: 28,
    });
  });
});

describe("S8 — each axis is clamped independently", () => {
  it("rest 80×28, proposal 74×30 → 74×28", () => {
    expect(clampGrid({ cols: 80, rows: 28 }, { cols: 74, rows: 30 })).toEqual({
      cols: 74,
      rows: 28,
    });
  });
});

describe("S8a — a zoom round trip is lossless", () => {
  // The property is about what the CALLER carries forward, so it is driven
  // through nextGrid: a zoom must not be allowed to replace the rest grid.
  const card = { cardH: 288, cardW: 718 };

  it("what the zoom-in gave up, the zoom-out gets back", () => {
    const mount = nextGrid({ cols: 74, rows: 31 }, null, card);
    expect(mount.grid).toEqual({ cols: 74, rows: 31 });

    // zoom in: the oversampled cell no longer fits 74 columns
    const zoomedIn = nextGrid({ cols: 72, rows: 31 }, mount.rest, card);
    expect(zoomedIn.grid).toEqual({ cols: 72, rows: 31 });
    expect(zoomedIn.rest).toBe(mount.rest); // the zoom did NOT re-record it

    // zoom out: back to the rest grid, not stuck at 72
    const zoomedOut = nextGrid({ cols: 74, rows: 31 }, zoomedIn.rest, card);
    expect(zoomedOut.grid).toEqual({ cols: 74, rows: 31 });
  });

  it("stays lossless across repeated zooming", () => {
    let state: RestGrid | null = nextGrid({ cols: 74, rows: 31 }, null, card).rest;
    for (const proposal of [{ cols: 72, rows: 31 }, { cols: 76, rows: 32 }, { cols: 73, rows: 30 }]) {
      state = nextGrid(proposal, state, card).rest;
    }
    expect(nextGrid({ cols: 74, rows: 31 }, state, card).grid).toEqual({ cols: 74, rows: 31 });
  });
});

describe("S13 — a rasterScale change clamps and keeps the rest grid", () => {
  // The same card at rs 1.5: the measured box is 1.5× bigger, the card is not.
  const rest: RestGrid = { grid: { cols: 74, rows: 31 }, cardH: 288, cardW: 718 };

  it("clamps the proposal when the card box is unchanged", () => {
    const { grid, rest: carried } = nextGrid({ cols: 76, rows: 32 }, rest, {
      cardH: 288,
      cardW: 718,
    });
    expect(grid).toEqual({ cols: 74, rows: 31 });
    expect(carried).toBe(rest);
  });

  it("tolerates the sub-pixel error of dividing an integer box by a fractional scale", () => {
    // clientHeight 433 at rs 1.5 → 288.67; the card really is 288.
    const { grid, rest: carried } = nextGrid({ cols: 76, rows: 32 }, rest, {
      cardH: 288.67,
      cardW: 718.4,
    });
    expect(grid).toEqual({ cols: 74, rows: 31 });
    expect(carried).toBe(rest);
  });
});

describe("S14 — a real card resize re-establishes the rest grid", () => {
  const rest: RestGrid = { grid: { cols: 74, rows: 31 }, cardH: 288, cardW: 718 };

  it("takes the proposal when the card grew, even though it is larger", () => {
    const { grid, rest: carried } = nextGrid({ cols: 80, rows: 36 }, rest, {
      cardH: 400,
      cardW: 718,
    });
    expect(grid).toEqual({ cols: 80, rows: 36 });
    expect(carried).toEqual({ grid: { cols: 80, rows: 36 }, cardH: 400, cardW: 718 });
  });

  it("re-establishes on a width-only resize", () => {
    const { grid } = nextGrid({ cols: 90, rows: 31 }, rest, { cardH: 288, cardW: 900 });
    expect(grid).toEqual({ cols: 90, rows: 31 });
  });

  it("a 1px drag step counts as a resize, not as rounding noise", () => {
    const { grid } = nextGrid({ cols: 74, rows: 32 }, rest, { cardH: 289, cardW: 718 });
    expect(grid).toEqual({ cols: 74, rows: 32 });
  });
});

describe("S15 — the first measurement establishes the rest grid", () => {
  it("with no rest grid the proposal is taken as-is and recorded", () => {
    const { grid, rest } = nextGrid({ cols: 74, rows: 31 }, null, { cardH: 288, cardW: 718 });
    expect(grid).toEqual({ cols: 74, rows: 31 });
    expect(rest).toEqual({ grid: { cols: 74, rows: 31 }, cardH: 288, cardW: 718 });
  });
});

describe("S16 — the card box divides the rasterScale out", () => {
  it("the same card measures equal at rs 1 and rs 1.5", () => {
    const at1 = cardBox(box({ boxH: 288, boxW: 718 }), 1);
    const at15 = cardBox(box({ boxH: 432, boxW: 1077 }), 1.5);
    expect(at1.cardH).toBe(432 / 1.5);
    expect(Math.abs(at1.cardH - at15.cardH)).toBeLessThanOrEqual(0.75);
    expect(Math.abs(at1.cardW - at15.cardW)).toBeLessThanOrEqual(0.75);
  });

  it("a real size difference lands outside the epsilon, rounding noise inside it", () => {
    // The epsilon has to separate "the same card measured at another raster
    // scale" from "the card was resized". Its band is (2/3, 1): the worst
    // sub-pixel disagreement between scales is 2/3 px, and a drag moves 1 px.
    const small = cardBox(box({ boxH: 288 }), 1);
    const big = cardBox(box({ boxH: 400 }), 1);
    expect(Math.abs(big.cardH - small.cardH)).toBeGreaterThan(CARD_BOX_EPSILON);
    expect(CARD_BOX_EPSILON).toBeGreaterThan(2 / 3);
    expect(CARD_BOX_EPSILON).toBeLessThan(1);
  });
});

describe("S17 — the scrollbar reserve mirrors xterm's own rule", () => {
  it("defaults to 14px", () => {
    expect(scrollbarReserve({ scrollback: 5000 })).toBe(14);
  });

  it("is 0 when there is no scrollback to scroll", () => {
    expect(scrollbarReserve({ scrollback: 0 })).toBe(0);
  });

  it("is 0 when the scrollbar is hidden", () => {
    expect(scrollbarReserve({ scrollback: 5000, scrollbar: { showScrollbar: false } })).toBe(0);
  });

  it("honours a configured width", () => {
    expect(scrollbarReserve({ scrollback: 5000, scrollbar: { width: 20 } })).toBe(20);
  });
});

describe("S9 — unusable cell metrics propose nothing", () => {
  it("a zero cell height returns null", () => {
    expect(proposeGrid(box({ cellH: 0 }))).toBeNull();
  });

  it("a zero cell width returns null", () => {
    expect(proposeGrid(box({ cellW: 0 }))).toBeNull();
  });

  it("a NaN cell height returns null", () => {
    // `> 0` is false for NaN, but a guard written as `!(v <= 0)` would let it
    // through and reach term.resize(), which throws on non-integers.
    expect(proposeGrid(box({ cellH: NaN }))).toBeNull();
  });

  it("a NaN cell width returns null", () => {
    // Asserted on its own axis: a guard that only checks cellH passes the other.
    expect(proposeGrid(box({ cellW: NaN }))).toBeNull();
  });
});

describe("S10 — an unmeasurable box proposes nothing", () => {
  it("a hidden board (0×0) returns null rather than 2×1", () => {
    expect(proposeGrid(box({ boxH: 0, boxW: 0 }))).toBeNull();
  });

  it("a zero height alone returns null", () => {
    expect(proposeGrid(box({ boxH: 0 }))).toBeNull();
  });

  it("a zero width alone returns null", () => {
    expect(proposeGrid(box({ boxW: 0 }))).toBeNull();
  });

  it("an infinite height returns null", () => {
    expect(proposeGrid(box({ boxH: Infinity }))).toBeNull();
  });

  it("an infinite width returns null", () => {
    expect(proposeGrid(box({ boxW: Infinity }))).toBeNull();
  });
});

describe("S10a — non-finite padding proposes nothing", () => {
  it("a NaN padV returns null", () => {
    // parseFloat of a computed style can fail; NaN must not reach term.resize().
    expect(proposeGrid(box({ padV: NaN }))).toBeNull();
  });

  it("a NaN padH returns null", () => {
    expect(proposeGrid(box({ padH: NaN }))).toBeNull();
  });

  it("a NaN scrollbar reserve returns null", () => {
    expect(proposeGrid(box({ scrollbar: NaN }))).toBeNull();
  });

  it("zero padding is legal, not a failure", () => {
    expect(proposeGrid(box({ padV: 0, padH: 0, scrollbar: 0 }))).not.toBeNull();
  });
});

describe("S12 — the host bottom-anchors its grid (CSS declaration lock)", () => {
  const css = readFileSync(
    fileURLToPath(new URL("../theme/app-only.css", import.meta.url)),
    "utf8",
  );
  // The EFFECTIVE value of a property on .term-host: the last declaration wins,
  // so appending an overriding rule later in the file is caught rather than
  // hidden behind the first block.
  const hostBlocks = [...css.matchAll(/\.term-host\s*\{([^}]*)\}/g)]
    .map((m) => m[1].replace(/\/\*[\s\S]*?\*\//g, "")); // comments carry colons too
  const effective = (prop: string): string | null => {
    let value: string | null = null;
    for (const block of hostBlocks) {
      for (const m of block.matchAll(new RegExp(`(?:^|;)\\s*${prop}\\s*:([^;]*)`, "g"))) {
        value = m[1].trim();
      }
    }
    return value;
  };

  it(".term-host is a bottom-anchored flex column", () => {
    // The leftover sub-row height lands ABOVE the first row, so the gutter under
    // the last row is exactly the declared 16·rs at every rasterScale.
    expect(effective("display")).toBe("flex");
    expect(effective("flex-direction")).toBe("column");
    expect(effective("justify-content")).toBe("flex-end");
  });

  it(".xterm never stretches to 100% of the host", () => {
    // height:100% would stretch the painted element over the remainder and put
    // the gap back under the last row. The assertion is on the ABSENCE: dropping
    // the rule entirely is also correct, since auto is the initial value.
    const xtermRules = [...css.matchAll(/\.term-host\s+\.xterm\s*\{([^}]*)\}/g)]
      .map((m) => m[1])
      .join("\n");
    expect(xtermRules).not.toMatch(/height:\s*100%/);
  });

  it("the padding is still declared in CSS, not handed over to JS", () => {
    // Spec 2609.0007: .term-host padding is declarative. Nothing in the grid
    // change may reintroduce an imperative padding write.
    expect(effective("padding")).toBe(
      "calc(2px * var(--rs, 1)) calc(10px * var(--rs, 1)) calc(16px * var(--rs, 1))",
    );
  });
});
