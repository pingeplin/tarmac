import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { termInnerBox } from "./termZoom";
import { CARD_BORDER_W_PX, CARD_HEADER_H_PX } from "./cardChrome";

describe("S3/S11 — inner box is zoom-free, and matches the box .card-body clips", () => {
  const css = readFileSync(fileURLToPath(new URL("../theme/card.css", import.meta.url)), "utf8");

  // Body only, not the whole card: the header is chrome and stays outside this
  // scale, or it gets upscaled from a 1× raster and terminal titles blur. Both
  // axes also drop the two card borders — .card is border-box, so .card-body is
  // 2·zoom smaller than the card on each axis, and a box that ignored them
  // overhung the body and had its last text row clipped (spec 2609.0011).
  it("width is card-w minus both borders, in world px", () => {
    expect(termInnerBox().width).toBe(`calc(var(--card-w) - ${2 * CARD_BORDER_W_PX}px)`);
  });

  it("height is card-h minus the header and both borders, in world px", () => {
    expect(termInnerBox().height).toBe(
      `calc(var(--card-h) - ${CARD_HEADER_H_PX + 2 * CARD_BORDER_W_PX}px)`,
    );
  });

  it("subtracts the header height card.css actually renders", () => {
    expect(css).toMatch(
      new RegExp(`\\.card-header\\s*\\{[^}]*height:\\s*calc\\(${CARD_HEADER_H_PX}px \\* var\\(--zoom\\)\\)`, "s"),
    );
  });

  it("subtracts the border width card.css actually renders", () => {
    expect(css).toMatch(
      new RegExp(`\\.card\\s*\\{[^}]*border-width:\\s*calc\\(${CARD_BORDER_W_PX}px \\* var\\(--zoom\\)\\)`, "s"),
    );
  });

  it("width does not reference --zoom", () => {
    expect(termInnerBox().width).not.toMatch(/var\(--zoom\)/);
  });

  it("height does not reference --zoom", () => {
    expect(termInnerBox().height).not.toMatch(/var\(--zoom\)/);
  });
});

describe("S4 — inner box carries the sole scale (exact form, no willChange)", () => {
  it("transform is exactly 'scale(var(--zoom))' — break: scale(calc(var(--zoom)/1)) fails", () => {
    expect(termInnerBox().transform).toBe("scale(var(--zoom))");
  });

  it("transformOrigin is '0 0'", () => {
    expect(termInnerBox().transformOrigin).toBe("0 0");
  });

  it("willChange key is absent", () => {
    expect("willChange" in termInnerBox()).toBe(false);
  });
});
