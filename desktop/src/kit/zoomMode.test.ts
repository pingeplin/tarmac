import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { declaredZoomMode, zoomCapable, effectiveZoomMode, ZOOM_PROBE_FACTOR } from "./zoomMode";

// Spec 2607.0006 — magnify zoom mode decision logic.
describe("declaredZoomMode (S1)", () => {
  it("recognizes magnify case- and whitespace-insensitively", () => {
    expect(declaredZoomMode("magnify")).toBe("magnify");
    expect(declaredZoomMode("  MAGNIFY  ")).toBe("magnify");
    expect(declaredZoomMode("Magnify")).toBe("magnify");
  });

  it("falls back to reveal for anything else", () => {
    expect(declaredZoomMode(null)).toBe("reveal");
    expect(declaredZoomMode(undefined)).toBe("reveal");
    expect(declaredZoomMode("")).toBe("reveal");
    expect(declaredZoomMode("reveal")).toBe("reveal");
    expect(declaredZoomMode("magnifying")).toBe("reveal");
  });
});

describe("zoomCapable (S2)", () => {
  it("is true when the layout viewport halves under probe zoom", () => {
    expect(zoomCapable({ base: 400, zoomed: 200 })).toBe(true);
  });

  it("is false when zoom left the viewport unchanged (no-op or rendering-only zoom)", () => {
    expect(zoomCapable({ base: 400, zoomed: 400 })).toBe(false);
  });

  it("is false when the viewport grew instead of shrinking", () => {
    expect(zoomCapable({ base: 400, zoomed: 800 })).toBe(false);
  });

  // ZOOM_PROBE_EXPECTED_RATIO must be DERIVED from ZOOM_PROBE_FACTOR (DoD), not
  // a hardcoded 0.5: a probe zoomed by exactly ZOOM_PROBE_FACTOR is the
  // definition of capable, and this ties the two constants together.
  it("is true for a probe halved by exactly ZOOM_PROBE_FACTOR", () => {
    expect(zoomCapable({ base: 400, zoomed: 400 / ZOOM_PROBE_FACTOR })).toBe(true);
  });
});

describe("effectiveZoomMode (S3)", () => {
  it("is magnify only when declared magnify and capable", () => {
    expect(effectiveZoomMode("magnify", true)).toBe("magnify");
  });

  it("is reveal for every other declared/capable combination", () => {
    expect(effectiveZoomMode("magnify", false)).toBe("reveal");
    expect(effectiveZoomMode("reveal", true)).toBe("reveal");
    expect(effectiveZoomMode("reveal", false)).toBe("reveal");
  });
});

describe("zoomCapable tolerance boundary (S7)", () => {
  it("is true just inside tolerance and false clearly outside it", () => {
    expect(zoomCapable({ base: 400, zoomed: 207 })).toBe(true); // ratio 0.5175
    expect(zoomCapable({ base: 400, zoomed: 220 })).toBe(false); // ratio 0.55
  });

  // Every other capable fixture in this suite has ratio >= 0.5, so nothing
  // else pins the lower half of the band — a mutant dropping Math.abs (i.e.
  // only rejecting ratios ABOVE expected) would pass every other assertion.
  it("is false when the ratio sits clearly below tolerance", () => {
    expect(zoomCapable({ base: 400, zoomed: 180 })).toBe(false); // ratio 0.45
  });
});

describe("zoomCapable fails closed on invalid input (S13)", () => {
  it("rejects zero, non-finite, and sign-flipped probes", () => {
    expect(zoomCapable({ base: 0, zoomed: 0 })).toBe(false);
    expect(zoomCapable({ base: NaN, zoomed: 200 })).toBe(false);
    expect(zoomCapable({ base: 400, zoomed: Infinity })).toBe(false);
    // Ratio is exactly 0.5 here — only the base > 0 guard rejects it.
    expect(zoomCapable({ base: -400, zoomed: -200 })).toBe(false);
  });
});

// ZOOM_PROBE_FACTOR is the one value mirrored across the JS/TS boundary (the
// socket_path() duplication precedent) — card_shim.js hardcodes the numeral
// it applies to the root instead of importing this module. Nothing else
// catches drift between the two, so this test reads the shim's source and
// pins the value it applies.
describe("card_shim.js mirrors ZOOM_PROBE_FACTOR", () => {
  it("applies the same probe zoom factor as the kit constant", () => {
    const shimSrc = readFileSync(
      fileURLToPath(new URL("../../src-tauri/src/card_shim.js", import.meta.url)),
      "utf8",
    );
    const match = shimSrc.match(/ZOOM_PROBE_FACTOR\s*=\s*(\d+(?:\.\d+)?)/);
    expect(match).not.toBeNull();
    expect(Number(match![1])).toBe(ZOOM_PROBE_FACTOR);
  });

  // Pinning the declaration alone doesn't catch the use site drifting to a
  // literal (e.g. root.style.zoom = 3) while the declared constant stays 2.
  it("applies the constant, not a literal, at the probe's zoom use site", () => {
    const shimSrc = readFileSync(
      fileURLToPath(new URL("../../src-tauri/src/card_shim.js", import.meta.url)),
      "utf8",
    );
    expect(shimSrc).toMatch(/style\.zoom\s*=\s*ZOOM_PROBE_FACTOR\b/);
  });
});
