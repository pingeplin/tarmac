import { describe, it, expect } from "vitest";
import { declaredZoomMode } from "./zoomMode";

// Spec 2607.0006 — magnify zoom mode decision logic. The capability probe that
// once split declared from effective died with the macOS 26 floor (#94), so the
// declaration is the whole verdict.
describe("declaredZoomMode (S1)", () => {
  it("recognizes magnify case- and whitespace-insensitively", () => {
    expect(declaredZoomMode("magnify")).toBe("magnify");
    expect(declaredZoomMode("  MAGNIFY  ")).toBe("magnify");
    expect(declaredZoomMode("Magnify")).toBe("magnify");
  });

  it("recognizes reveal case- and whitespace-insensitively — the only opt-out", () => {
    expect(declaredZoomMode("reveal")).toBe("reveal");
    expect(declaredZoomMode("  REVEAL  ")).toBe("reveal");
    expect(declaredZoomMode("Reveal")).toBe("reveal");
  });

  it("defaults to magnify when the meta is absent", () => {
    expect(declaredZoomMode(null)).toBe("magnify");
    expect(declaredZoomMode(undefined)).toBe("magnify");
    expect(declaredZoomMode("")).toBe("magnify");
  });

  it("defaults to magnify on a malformed value — opting out must be deliberate", () => {
    expect(declaredZoomMode("revealing")).toBe("magnify");
    expect(declaredZoomMode("magnifying")).toBe("magnify");
    expect(declaredZoomMode("rEvEaL more")).toBe("magnify");
  });
});
