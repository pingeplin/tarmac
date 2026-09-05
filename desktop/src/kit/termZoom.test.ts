import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { termInnerBox } from "./termZoom";
import { CARD_HEADER_H_PX } from "./cardChrome";

describe("S3 — inner box is zoom-free (no --zoom in width/height)", () => {
  it("width is exactly 'var(--card-w)' — break: calc(...*var(--zoom)) fails this", () => {
    expect(termInnerBox().width).toBe("var(--card-w)");
  });

  // Body only, not the whole card: the header is chrome and stays outside this
  // scale, or it gets upscaled from a 1× raster and terminal titles blur.
  it("height is card-h minus the header, in world px", () => {
    expect(termInnerBox().height).toBe(`calc(var(--card-h) - ${CARD_HEADER_H_PX}px)`);
  });

  it("subtracts the header height card.css actually renders", () => {
    const css = readFileSync(fileURLToPath(new URL("../theme/card.css", import.meta.url)), "utf8");
    expect(css).toMatch(
      new RegExp(`\\.card-header\\s*\\{[^}]*height:\\s*calc\\(${CARD_HEADER_H_PX}px \\* var\\(--zoom\\)\\)`, "s"),
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
