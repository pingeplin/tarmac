import { describe, it, expect } from "vitest";
import { resolveOwner, docsOwnedBy, type Owners } from "./docRouting";

// Port of DocRoutingTests.swift: per-board doc→terminal owner resolution (a doc
// binds to its terminal, scoped to one board's owners + live terminals).
describe("DocRouting", () => {
  // owner present and live → resolves to that owner.
  it("owner present and live resolves", () => {
    const owner = resolveOwner("/a.md", { "/a.md": "t1" }, new Set(["t1", "t2"]));
    expect(owner).toBe("t1");
  });

  // The owning terminal vanished (e.g. a stale id after a restart remap): the
  // doc stays loose.
  it("owner present but not live is undefined", () => {
    const owner = resolveOwner("/a.md", { "/a.md": "gone" }, new Set(["t1"]));
    expect(owner).toBeUndefined();
  });

  // No owner entry for the doc → loose.
  it("no owner entry is undefined", () => {
    const owner = resolveOwner("/a.md", {}, new Set(["t1"]));
    expect(owner).toBeUndefined();
  });

  // The same doc/owner pair resolves only on the board whose live terminals
  // include the owner — board B (no t1) leaves it loose.
  it("cross-board isolation", () => {
    const owners: Owners = { "/a.md": "t1" };
    const onBoardA = resolveOwner("/a.md", owners, new Set(["t1"]));
    const onBoardB = resolveOwner("/a.md", owners, new Set(["t9"]));
    expect(onBoardA).toBe("t1");
    expect(onBoardB).toBeUndefined();
  });

  // docsOwnedBy (the inverse: a terminal's docs, for ⌘P focus targeting).

  it("docsOwnedBy returns every path for that terminal", () => {
    const owned = docsOwnedBy("t1", { "/a.md": "t1", "/b.md": "t2", "/c.md": "t1" });
    // Order is unspecified (dictionary); membership is the contract.
    expect(new Set(owned)).toEqual(new Set(["/a.md", "/c.md"]));
  });

  it("docsOwnedBy is empty when terminal owns nothing", () => {
    expect(docsOwnedBy("t9", { "/a.md": "t1" })).toEqual([]);
    expect(docsOwnedBy("t1", {})).toEqual([]);
  });
});
