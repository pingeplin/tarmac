import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { termHostPadding } from "./termHostPadding";

describe("termHostPadding", () => {
  it("returns the base values at rs=1", () => {
    expect(termHostPadding(1)).toBe("8px 10px 16px");
  });

  it("scales all three values by rs at rs=2", () => {
    expect(termHostPadding(2)).toBe("16px 20px 32px");
  });

  // S5 (spec 2609.0005): TerminalCard now writes this padding inline on every
  // terminal host at every rasterScale, so the .term-host rule is inert at
  // runtime and a drift between the two would surface nowhere else.
  it("equals the padding .term-host declares in theme/app-only.css", () => {
    const css = readFileSync(fileURLToPath(new URL("../theme/app-only.css", import.meta.url)), "utf8");
    const declared = css.match(/\.term-host\s*\{[^}]*padding:\s*([^;]+);/)?.[1].trim();
    expect(declared).toBe(termHostPadding(1));
  });
});
