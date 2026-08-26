import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { termWrapperBox, termCardVars, termInnerBox, CARD_HEADER_H_PX } from "./termZoom";
import { docWrapperBox } from "./docZoom";
import { worldToView } from "./boardTransform";
import { evalWrapperTranslate } from "./cssEval";

describe("S1 — outer wrapper equals doc formula (translate-only, no scale)", () => {
  it("termWrapperBox() is string-for-string identical to docWrapperBox()", () => {
    expect(termWrapperBox()).toStrictEqual(docWrapperBox());
  });

  it("transform has no scale( — break: adding scale(var(--zoom)) fails this", () => {
    expect(termWrapperBox().transform).not.toMatch(/scale\(/);
  });
});

describe("S2 — outer wrapper has no willChange", () => {
  it("willChange key is absent — break: adding willChange:'transform' fails this", () => {
    expect("willChange" in termWrapperBox()).toBe(false);
  });
});

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

describe("S5 — termCardVars produces --card-* px strings", () => {
  it("returns all four custom properties with px suffix — break: dropping px fails", () => {
    expect(termCardVars({ x: 100, y: 200, w: 360, h: 480 })).toStrictEqual({
      "--card-x": "100px",
      "--card-y": "200px",
      "--card-w": "360px",
      "--card-h": "480px",
    });
  });
});

describe("S6 — outer origin projects via worldToView (eval actual transform string)", () => {
  it("at zoom 2 the eval'd translate matches worldToView — break: wrong sign on --world-ty diverges", () => {
    const zoom = 2, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom;
    const ty = viewH / 2 - cy * zoom;

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
      "--device-px": "1px",
    };

    const { transform } = termWrapperBox();
    const { x: screenX, y: screenY } = evalWrapperTranslate(transform, vars);

    const proj = worldToView(
      { x: cardX, y: cardY },
      zoom,
      { x: cx, y: cy },
      { x: viewW / 2, y: viewH / 2 },
    );

    expect(screenX).toBeCloseTo(proj.x);
    expect(screenY).toBeCloseTo(proj.y);
  });

  it("at zoom 0.5 the eval'd translate matches worldToView", () => {
    const zoom = 0.5, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom;
    const ty = viewH / 2 - cy * zoom;

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
      "--device-px": "1px",
    };

    const { transform } = termWrapperBox();
    const { x: screenX, y: screenY } = evalWrapperTranslate(transform, vars);

    const proj = worldToView(
      { x: cardX, y: cardY },
      zoom,
      { x: cx, y: cy },
      { x: viewW / 2, y: viewH / 2 },
    );

    expect(screenX).toBeCloseTo(proj.x);
    expect(screenY).toBeCloseTo(proj.y);
  });
});
