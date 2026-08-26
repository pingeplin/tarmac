import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  docProseLayout,
  docWrapperBox,
  docCardVars,
  docProseScaler,
  DOC_PROSE_FONT_SIZE_PX,
  DOC_PROSE_MAX_WIDTH_PX,
  DOC_SCROLL_PADDING_V_PX,
  DOC_SCROLL_PADDING_H_PX,
  DOC_OVERSAMPLE_K,
} from "./docZoom";
import { worldToView } from "./boardTransform";
import { MAX_ZOOM } from "../board/BoardEngine";
// Derives the screen (x,y) from the ACTUAL docWrapperBox().transform string, so
// the test reads the live string rather than a hand-derived formula.
import { evalWrapperTranslate } from "./cssEval";

describe("S4 — prose layout frozen (no zoom parameter)", () => {
  it("returns the four named constants", () => {
    const layout = docProseLayout();
    expect(layout.fontSizePx).toBe(DOC_PROSE_FONT_SIZE_PX);
    expect(layout.maxWidthPx).toBe(DOC_PROSE_MAX_WIDTH_PX);
    expect(layout.paddingVPx).toBe(DOC_SCROLL_PADDING_V_PX);
    expect(layout.paddingHPx).toBe(DOC_SCROLL_PADDING_H_PX);
  });

  it("fontSizePx is 14, maxWidthPx is 720, paddingVPx is 18, paddingHPx is 22", () => {
    const { fontSizePx, maxWidthPx, paddingVPx, paddingHPx } = docProseLayout();
    expect(fontSizePx).toBe(14);
    expect(maxWidthPx).toBe(720);
    expect(paddingVPx).toBe(18);
    expect(paddingHPx).toBe(22);
  });

  it("zero declared parameters — sizing structurally cannot depend on zoom", () => {
    expect(docProseLayout.length).toBe(0);
  });
});

describe("S1 — box size + translate-only position", () => {
  it("width is calc(var(--card-w) * var(--zoom))", () => {
    expect(docWrapperBox().width).toBe("calc(var(--card-w) * var(--zoom))");
  });

  it("height is calc(var(--card-h) * var(--zoom))", () => {
    expect(docWrapperBox().height).toBe("calc(var(--card-h) * var(--zoom))");
  });

  it("transform is the exact translate-only calc string, device-pixel snapped", () => {
    expect(docWrapperBox().transform).toBe(
      "translate(round(calc(var(--world-tx) + var(--card-x) * var(--zoom)),var(--device-px)),round(calc(var(--world-ty) + var(--card-y) * var(--zoom)),var(--device-px)))",
    );
  });

  it("transformOrigin is '0 0'", () => {
    expect(docWrapperBox().transformOrigin).toBe("0 0");
  });
});

describe("S2 — box carries NO scale, no willChange", () => {
  it("transform contains no scale(", () => {
    expect(docWrapperBox().transform).not.toMatch(/scale\(/);
  });

  it("willChange key is absent from the returned object", () => {
    expect("willChange" in docWrapperBox()).toBe(false);
  });
});

describe("S3 — prose is the sole scale (Panel H down-scale)", () => {
  it("transform divides zoom by --oversample-k (down-scale form)", () => {
    expect(docProseScaler().transform).toBe(
      "scale(calc(var(--zoom) / var(--oversample-k)))",
    );
  });

  it("contains exactly one scale( and it references --oversample-k", () => {
    const { transform } = docProseScaler();
    const hits = transform.match(/scale\(/g);
    expect(hits).toHaveLength(1);
    expect(transform).toMatch(/var\(--oversample-k\)/);
    // Down-scale, not up-scale: zoom is DIVIDED, not bare scale(var(--zoom)).
    expect(transform).not.toBe("scale(var(--zoom))");
  });

  it("transformOrigin is '0 0'", () => {
    expect(docProseScaler().transformOrigin).toBe("0 0");
  });

  it("is bare — no width key and no willChange key", () => {
    const style = docProseScaler();
    expect("width" in style).toBe(false);
    expect("willChange" in style).toBe(false);
  });
});

describe("S12 — prose layout is zoom-INDEPENDENT (reflow regression)", () => {
  // The frozen K× layout lives on the .doc-prose rule in theme/card.css (moved
  // out of theme.css by the theme/*.css partial split — see
  // docs/designs/2607.0001_tarmac_ui_kit_design_sync_export.md); it must
  // depend only on --oversample-k / --card-w, never on --zoom — otherwise wrap
  // points move with zoom and the prose re-wraps. The bare scaler is the SOLE
  // carrier of --zoom.
  const themeCss = readFileSync(
    fileURLToPath(new URL("../theme/card.css", import.meta.url)),
    "utf8",
  );

  /** Extract the body of a top-level CSS rule by exact selector. */
  function ruleBody(selector: string): string {
    const i = themeCss.indexOf(selector + " {");
    expect(i, `selector ${selector} not found in theme/card.css`).toBeGreaterThanOrEqual(0);
    const open = themeCss.indexOf("{", i);
    const close = themeCss.indexOf("}", open);
    return themeCss.slice(open + 1, close);
  }

  it(".doc-prose rule contains no var(--zoom)", () => {
    expect(ruleBody(".doc-prose")).not.toMatch(/var\(--zoom\)/);
  });

  it(".doc-prose layout metrics reference --oversample-k", () => {
    expect(ruleBody(".doc-prose")).toMatch(/var\(--oversample-k\)/);
  });

  it("the bare scaler is the carrier of --zoom, not the prose", () => {
    expect(docProseScaler().transform).toMatch(/var\(--zoom\)/);
  });
});

describe("S14 — wrapper translate snaps to whole device pixels", () => {
  // world-tx = viewW/2 - cx*zoom is a raw float, so the unsnapped translate lands
  // the card's raster off the device grid and WebKit filters it — every glyph and
  // hairline in the card softens on a 1× display while the board's own transform-
  // free chrome stays sharp. Snapping is what closes that gap.
  const cases = [
    { devicePx: 1, tx: 380.4, want: 380 },
    { devicePx: 1, tx: 380.6, want: 381 },
    { devicePx: 0.5, tx: 380.4, want: 380.5 }, // Retina: half-CSS-px grid
    { devicePx: 0.5, tx: 380.1, want: 380 },
  ];

  for (const { devicePx, tx, want } of cases) {
    it(`--device-px ${devicePx}px snaps ${tx} to ${want}`, () => {
      const vars: Record<string, string> = {
        "--world-tx": `${tx}px`,
        "--world-ty": `${tx}px`,
        "--card-x": "0px",
        "--card-y": "0px",
        "--zoom": "1",
        "--device-px": `${devicePx}px`,
      };
      const { x, y } = evalWrapperTranslate(docWrapperBox().transform, vars);
      expect(x).toBeCloseTo(want);
      expect(y).toBeCloseTo(want);
    });
  }
});

describe("S13 — K never upsamples", () => {
  // K >= the engine's MAX_ZOOM guarantees scale(zoom/K) <= 1 across the whole
  // range, so the prose layer is only ever DOWN-scaled (crisp, never bitmap-
  // upscaled). Imported from BoardEngine so raising MAX_ZOOM above K fails here.
  it("DOC_OVERSAMPLE_K is >= the engine MAX_ZOOM", () => {
    expect(DOC_OVERSAMPLE_K).toBeGreaterThanOrEqual(MAX_ZOOM);
  });

  it("at max zoom the prose scale factor is <= 1 (never an upsample)", () => {
    expect(MAX_ZOOM / DOC_OVERSAMPLE_K).toBeLessThanOrEqual(1);
  });
});

describe("S5 — per-card vars from frame", () => {
  it("returns the four --card-* custom properties as px strings", () => {
    expect(docCardVars({ x: 100, y: 200, w: 360, h: 480 })).toStrictEqual({
      "--card-x": "100px",
      "--card-y": "200px",
      "--card-w": "360px",
      "--card-h": "480px",
    });
  });

  it("re-render with the same frame produces byte-identical vars (no position snap)", () => {
    const frame = { x: 77, y: 33, w: 400, h: 300 };
    expect(docCardVars(frame)).toStrictEqual(docCardVars(frame));
  });
});

describe("S6 — box origin projects via worldToView (non-vacuous: derived from actual transform string)", () => {
  // The engine sets --world-tx = viewW/2 - cx*zoom, --world-ty = viewH/2 - cy*zoom.
  // We substitute those values INTO the actual docWrapperBox().transform string
  // (via evalWrapperTranslate), so if docWrapperBox() returned the wrong string
  // (e.g., the old scale() form), the eval would produce a wrong result or throw.

  it("box origin at zoom 2 matches worldToView projection", () => {
    const zoom = 2, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom; // 380
    const ty = viewH / 2 - cy * zoom; // 260

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
      "--device-px": "1px",
    };

    // Derive screen point from the ACTUAL transform string, not by hand
    const { transform } = docWrapperBox();
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

  it("box origin at zoom 0.5 matches worldToView projection", () => {
    const zoom = 0.5, cx = 10, cy = 20, viewW = 800, viewH = 600;
    const cardX = 50, cardY = 30;
    const tx = viewW / 2 - cx * zoom; // 395
    const ty = viewH / 2 - cy * zoom; // 290

    const vars: Record<string, string> = {
      "--world-tx": `${tx}px`,
      "--world-ty": `${ty}px`,
      "--card-x": `${cardX}px`,
      "--card-y": `${cardY}px`,
      "--zoom": String(zoom),
      "--device-px": "1px",
    };

    const { transform } = docWrapperBox();
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
