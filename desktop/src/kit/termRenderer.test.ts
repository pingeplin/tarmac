import { describe, it, expect } from "vitest";
import {
  INITIAL_RENDERER_STATE,
  shouldAttemptWebgl,
  onWebglLoaded,
  onContextLoss,
  onWebglUnavailable,
} from "./termRenderer";

describe("INITIAL_RENDERER_STATE", () => {
  it("is canvas with WebGL still eligible", () => {
    expect(INITIAL_RENDERER_STATE).toEqual({ kind: "canvas", webglDisabled: false });
  });
});

describe("shouldAttemptWebgl", () => {
  it("S1 — returns true when supported and state is fresh", () => {
    expect(shouldAttemptWebgl(INITIAL_RENDERER_STATE, true)).toBe(true);
  });

  it("S2 — returns false once kind is webgl (never re-attempts)", () => {
    const loaded = onWebglLoaded(INITIAL_RENDERER_STATE);
    expect(loaded).toEqual({ kind: "webgl", webglDisabled: false });
    expect(shouldAttemptWebgl(loaded, true)).toBe(false);
  });

  it("S4 — returns false after context loss even when supported=true", () => {
    const lost = onContextLoss(onWebglLoaded(INITIAL_RENDERER_STATE));
    expect(shouldAttemptWebgl(lost, true)).toBe(false);
  });

  it("S5 — returns false when supported=false", () => {
    expect(shouldAttemptWebgl(INITIAL_RENDERER_STATE, false)).toBe(false);
  });
});

describe("onWebglLoaded", () => {
  it("S2 — transitions to webgl, webglDisabled stays false", () => {
    expect(onWebglLoaded(INITIAL_RENDERER_STATE)).toEqual({
      kind: "webgl",
      webglDisabled: false,
    });
  });
});

describe("onContextLoss", () => {
  it("S3 — transitions webgl → canvas and latches webglDisabled", () => {
    const webgl = onWebglLoaded(INITIAL_RENDERER_STATE);
    const lost = onContextLoss(webgl);
    expect(lost).toEqual({ kind: "canvas", webglDisabled: true });
  });

  it("S3 — is idempotent (applying twice yields the same value)", () => {
    const webgl = onWebglLoaded(INITIAL_RENDERER_STATE);
    const once = onContextLoss(webgl);
    const twice = onContextLoss(once);
    expect(twice).toEqual(once);
    expect(twice.kind).toBe("canvas");
    expect(twice.webglDisabled).toBe(true);
  });
});

describe("onWebglUnavailable", () => {
  it("S5 — stays canvas and latches webglDisabled without throwing", () => {
    expect(() => onWebglUnavailable(INITIAL_RENDERER_STATE)).not.toThrow();
    const result = onWebglUnavailable(INITIAL_RENDERER_STATE);
    expect(result).toEqual({ kind: "canvas", webglDisabled: true });
    expect(shouldAttemptWebgl(result, true)).toBe(false);
  });
});
