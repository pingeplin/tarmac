// Port of TarmacKitTests/TermRestoreTests.swift — the re-bind-vs-cold-spawn
// partition for terminal restore (P5).
import { describe, it, expect } from "vitest";
import { plan, type Plan } from "./termRestore";

describe("termRestore.plan", () => {
  it("re-binds a tile whose id is live", () => {
    const plans = plan(["t0"], new Set(["t0"]));
    expect(plans).toEqual<Plan[]>([{ kind: "rebind", termId: "t0" }]);
  });

  it("cold-spawns a dead tile", () => {
    // The persisted id is not among the daemon's live terms (it exited, or the
    // daemon restarted) → cold-spawn.
    const plans = plan(["t0"], new Set());
    expect(plans).toEqual<Plan[]>([{ kind: "coldSpawn" }]);
  });

  it("cold-spawns a null term id", () => {
    const plans = plan([null], new Set(["t0"]));
    expect(plans).toEqual<Plan[]>([{ kind: "coldSpawn" }]);
  });

  it("preserves tile order across a mix", () => {
    // Two shells survived (t0, t2), one died (t1) — each tile decides
    // independently and order is preserved (tile 0 becomes the prime).
    const plans = plan(["t0", "t1", "t2"], new Set(["t0", "t2"]));
    expect(plans).toEqual<Plan[]>([
      { kind: "rebind", termId: "t0" },
      { kind: "coldSpawn" },
      { kind: "rebind", termId: "t2" },
    ]);
  });

  it("cold-spawns every tile when the daemon restarted", () => {
    // Empty liveTerms (daemon restarted, all shells gone) ⇒ every tile cold-
    // spawns — the pre-P5 behaviour, byte-for-byte.
    const plans = plan(["t0", "t1"], new Set());
    expect(plans).toEqual<Plan[]>([{ kind: "coldSpawn" }, { kind: "coldSpawn" }]);
  });

  it("returns an empty plan for empty tiles", () => {
    expect(plan([], new Set(["t0"]))).toEqual<Plan[]>([]);
  });
});
