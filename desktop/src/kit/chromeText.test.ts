// Tests for the small chrome-text formatters (zoom %, titlebar label fallback,
// peek recency meta). Net-new — the Swift equivalents were inline expressions in
// the untested AppKit layer.

import { describe, it, expect } from "vitest";
import { formatZoomPct, boardChipLabel, recencyLabel, RECENT_WINDOW_MS } from "./chromeText";

describe("formatZoomPct", () => {
  it("rounds to whole percent, half away from zero", () => {
    expect(formatZoomPct(1)).toBe("100%");
    expect(formatZoomPct(0.125)).toBe("13%"); // 12.5 -> 13 (exact half, away from zero)
    expect(formatZoomPct(0.1)).toBe("10%");
    expect(formatZoomPct(3)).toBe("300%");
  });
});

describe("boardChipLabel", () => {
  it("uses the name when present", () => {
    expect(boardChipLabel("Frontend", "b-1")).toBe("Frontend");
  });
  it("falls back to the id for null / undefined / empty name", () => {
    expect(boardChipLabel(null, "b-1")).toBe("b-1");
    expect(boardChipLabel(undefined, "b-2")).toBe("b-2");
    expect(boardChipLabel("", "b-3")).toBe("b-3");
  });
});

describe("recencyLabel", () => {
  it("is null without a change time", () => {
    expect(recencyLabel(undefined, 1000)).toBeNull();
  });
  it("formats whole seconds, floored at 1, within the window", () => {
    expect(recencyLabel(1000, 1000)).toBe("✎ 1s");
    expect(recencyLabel(1000, 1500)).toBe("✎ 1s");
    expect(recencyLabel(1000, 2600)).toBe("✎ 2s");
  });
  it("is null at / after the 30s boundary", () => {
    expect(recencyLabel(1000, 1000 + RECENT_WINDOW_MS)).toBeNull();
  });
  it("treats a future change time as recent (clamps to ✎ 1s, matches isRecent / Swift)", () => {
    expect(recencyLabel(2000, 1000)).toBe("✎ 1s");
  });
});
