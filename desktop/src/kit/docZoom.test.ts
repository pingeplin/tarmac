import { describe, it, expect } from "vitest";
import {
  docProseLayout,
  docScalerStyle,
  DOC_PROSE_FONT_SIZE_PX,
  DOC_PROSE_MAX_WIDTH_PX,
  DOC_SCROLL_PADDING_V_PX,
  DOC_SCROLL_PADDING_H_PX,
} from "./docZoom";

describe("docProseLayout", () => {
  // S1 / S7a: sizing returns exactly the named constants, no zoom arithmetic.
  it("S1/S7a: returns exactly the four named constants", () => {
    const layout = docProseLayout();
    expect(layout.fontSizePx).toBe(DOC_PROSE_FONT_SIZE_PX);
    expect(layout.maxWidthPx).toBe(DOC_PROSE_MAX_WIDTH_PX);
    expect(layout.paddingVPx).toBe(DOC_SCROLL_PADDING_V_PX);
    expect(layout.paddingHPx).toBe(DOC_SCROLL_PADDING_H_PX);
  });

  it("S1: fontSizePx is 14 (base prose size, never zoom-derived)", () => {
    expect(docProseLayout().fontSizePx).toBe(14);
  });

  it("S1: maxWidthPx is 720 (base max-width, never zoom-derived)", () => {
    expect(docProseLayout().maxWidthPx).toBe(720);
  });

  it("S1: paddingVPx is 18 and paddingHPx is 22", () => {
    const { paddingVPx, paddingHPx } = docProseLayout();
    expect(paddingVPx).toBe(18);
    expect(paddingHPx).toBe(22);
  });
});

describe("docScalerStyle", () => {
  // S2: transform must not contain scale() — it is a static layer hint only.
  // A scale() here would compose with the ancestor .world zoom → zoom².
  it("S2: transform does not contain scale()", () => {
    expect(docScalerStyle().transform).not.toMatch(/scale\(/);
  });

  it("S2: transform is translateZ(0) — layer promotion only", () => {
    expect(docScalerStyle().transform).toBe("translateZ(0)");
  });

  // S3: output is deeply equal across all calls — no zoom coupling.
  it("S3: every call returns a deeply-equal object", () => {
    const a = docScalerStyle();
    const b = docScalerStyle();
    const c = docScalerStyle();
    expect(a).toEqual(b);
    expect(b).toEqual(c);
  });

  // S5: origin matches the world-transform origin.
  it("S5: transformOrigin is '0 0'", () => {
    expect(docScalerStyle().transformOrigin).toBe("0 0");
  });

  // S6: willChange must be absent — it pins the layer raster at 1× → permanent blur.
  it("S6: willChange is not present in the style object", () => {
    expect("willChange" in docScalerStyle()).toBe(false);
  });
});
