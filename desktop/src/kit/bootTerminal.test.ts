import { describe, it, expect } from "vitest";
import { mint } from "./bootTerminal";

// Port of BootTerminalTests.swift (M3): the single home for terminal-id minting.
describe("BootTerminal", () => {
  it("mint is non-empty", () => {
    expect(mint().length).toBeGreaterThan(0);
  });

  it("two mints differ", () => {
    expect(mint()).not.toBe(mint());
  });

  it("many mints are unique", () => {
    const ids = Array.from({ length: 1000 }, () => mint());
    expect(new Set(ids).size).toBe(ids.length);
  });
});
