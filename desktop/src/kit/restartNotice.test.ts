// Spec 2609.0017 (#172): the first-visit notice after a version-mismatch
// restart. Every expected string is pasted from the spec's Interface Contract.
import { describe, it, expect } from "vitest";
import { restartNotice } from "./restartNotice";

describe("restartNotice", () => {
  const replaced = { from: "0.12.2", to: "0.12.3" };

  it("S1: names both versions and counts the lost terminals", () => {
    expect(restartNotice(replaced, ["t1", "t2"], new Set(), false)).toEqual({
      title: "tarmacd restarted: 0.12.2 → 0.12.3",
      body: "2 terminals on this board were restarted",
    });
  });

  it("S1: the plural count leaves out terminals that came back live", () => {
    expect(restartNotice(replaced, ["t1", "t2", "t3"], new Set(["t1"]), false)?.body).toBe(
      "2 terminals on this board were restarted",
    );
  });

  it("S1: the plural body carries the lost count, not a fixed number", () => {
    expect(restartNotice(replaced, ["t1", "t2", "t3", "t4"], new Set(["t1"]), false)?.body).toBe(
      "3 terminals on this board were restarted",
    );
  });

  it("S3: a cold start with no replaced daemon gets no notice", () => {
    expect(restartNotice(undefined, ["t1"], new Set(), false)).toBeNull();
  });

  it("S4: a fresh ⌘N board, whose tile has no persisted id, gets no notice", () => {
    expect(restartNotice(replaced, [null], new Set(), false)).toBeNull();
  });

  it("S5: terminals that came back live get no notice", () => {
    expect(restartNotice(replaced, ["t1", "t2"], new Set(["t1", "t2"]), false)).toBeNull();
  });

  it("S6: counts only persisted ids that are not live, in the singular for one", () => {
    expect(restartNotice(replaced, ["t1", "t2", null], new Set(["t1"]), false)?.body).toBe(
      "1 terminal on this board was restarted",
    );
  });

  it("S6: live ids from other boards do not reduce the count, and null tiles never count", () => {
    expect(restartNotice(replaced, ["t1", "t2", null, null], new Set(["t9"]), false)?.body).toBe(
      "2 terminals on this board were restarted",
    );
  });

  it("S7: a replaced daemon that reported no version reads as unknown", () => {
    const replaced = { from: null, to: "0.12.3" };
    expect(restartNotice(replaced, ["t1"], new Set(), false)?.title).toBe(
      "tarmacd restarted: unknown → 0.12.3",
    );
  });

  it("S7b: a respawned daemon that reported no version reads as unknown", () => {
    const replaced = { from: "0.12.2", to: null };
    expect(restartNotice(replaced, ["t1"], new Set(), false)?.title).toBe(
      "tarmacd restarted: 0.12.2 → unknown",
    );
  });

  it("S8: a restart already notified gets no second notice", () => {
    expect(restartNotice(replaced, ["t1", "t2"], new Set(), true)).toBeNull();
  });

  it("S9: a board with no terminal tiles gets no notice", () => {
    expect(restartNotice(replaced, [], new Set(), false)).toBeNull();
  });
});
