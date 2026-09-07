import { describe, it, expect } from "vitest";
import { devTitleSuffix } from "./devTitle";

// Spec 2609.0009 — S1 (a label yields a suffix) and S2 (no label yields none).
describe("devTitleSuffix (S1)", () => {
  it("appends the worktree label", () => {
    expect(devTitleSuffix("102-dev-bundle-id")).toBe(" · 102-dev-bundle-id");
  });

  it("trims, so padding never reaches the title", () => {
    expect(devTitleSuffix("  41-reload  ")).toBe(devTitleSuffix("41-reload"));
  });
});

describe("devTitleSuffix (S2)", () => {
  it("yields nothing for an absent or blank label", () => {
    expect(devTitleSuffix(undefined)).toBe("");
    expect(devTitleSuffix("")).toBe("");
    expect(devTitleSuffix("   \t ")).toBe("");
  });
});
