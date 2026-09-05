import { describe, it, expect } from "vitest";
import { declaredZoomMode, readyActions, type ZoomMode } from "./zoomMode";
import { MAGNIFY_K } from "./cardZoom";

// Spec 2607.0006 S1 — magnify zoom mode decision logic. The capability probe that
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

// Spec 2609.0003 (#99) — the per-`ready` verdict. Before this, the host posted
// root zoom only for a load's FIRST ready, so a document that reloaded itself
// (same src, same lastChangedMs, so the host's per-load state never reset) was
// sent no zoom at all and came back rendered at 1/K.
//
// Ids are namespaced `2609.0003 S<n>` because this file already cites 2607.0006's
// S1 above, and card-shim.test.ts carries a different S8/S9/S10 again.
//
// The payload is compared against the imported MAGNIFY_K, never a literal, so a
// wrong constant fails here rather than only in QA.
const MAGNIFY_POST = { tarmac: "zoom", z: MAGNIFY_K };
const logLine = (mode: ZoomMode) => `zoom-mode declared=${mode} effective=${mode}`;

describe("2609.0003 readyActions — a load's first ready (S1-S3, guards)", () => {
  // S1-S3 characterize behaviour that already shipped; they fail today only
  // because readyActions did not exist yet.
  it("2609.0003 S1: adopts magnify, logs the line and posts the zoom when magnify is declared", () => {
    expect(readyActions(null, "magnify")).toEqual({
      adopt: "magnify",
      logLine: logLine("magnify"),
      zoomPost: MAGNIFY_POST,
    });
  });

  it("2609.0003 S2: a meta-less document takes the magnify default and posts, but logs nothing", () => {
    expect(readyActions(null, null)).toEqual({
      adopt: "magnify",
      logLine: null,
      zoomPost: MAGNIFY_POST,
    });
  });

  // The shim's `el.content || ""` really can deliver "", and a typo is still a
  // tag the author wrote. Only an ABSENT tag is silent. Expected values are
  // literal per row — recomputing them from `meta` would re-implement the
  // function under test and assert nothing.
  it.each([
    ["", "magnify", MAGNIFY_POST],
    ["banana", "magnify", MAGNIFY_POST],
    ["magnifying", "magnify", MAGNIFY_POST],
    ["  REVEAL  ", "reveal", null],
  ] as const)(
    "2609.0003 S2: a present-but-useless tag (%j) still logs, resolving to %s",
    (meta, mode, post) => {
      expect(readyActions(null, meta)).toEqual({
        adopt: mode,
        logLine: logLine(mode),
        zoomPost: post,
      });
    },
  );

  it("2609.0003 S3: adopts reveal, logs the line and posts nothing when reveal is declared", () => {
    expect(readyActions(null, "reveal")).toEqual({
      adopt: "reveal",
      logLine: logLine("reveal"),
      zoomPost: null,
    });
  });
});

// Every shape that must carry the frozen constant — first ready and repeat
// alike, which is why this sits outside both describes above. Cased so a failure
// names which shape drifted.
describe("2609.0003 readyActions — the posted zoom is always MAGNIFY_K (S5)", () => {
  const K_POST_CASES: Array<[string, ZoomMode | null, string | null]> = [
    ["a first magnify ready", null, "magnify"],
    ["a first meta-less ready", null, null],
    ["a meta-less repeat", "magnify", null],
    ["a repeat forging reveal", "magnify", "reveal"],
  ];
  it.each(K_POST_CASES)(
    "2609.0003 S5: %s posts MAGNIFY_K, not some other zoom",
    (_label, inForce, meta) => {
      expect(readyActions(inForce, meta).zoomPost).toEqual({ tarmac: "zoom", z: MAGNIFY_K });
    },
  );
});

describe("2609.0003 readyActions — a repeat ready (S4, S6-S7)", () => {
  it("2609.0003 S4: the self-reload shape is answered with the zoom, adopting and logging nothing", () => {
    expect(readyActions("magnify", "magnify")).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: MAGNIFY_POST,
    });
  });

  it("2609.0003 S4: and with no meta at all — the commoner real shape (cull-qa S36's fixture)", () => {
    expect(readyActions("magnify", null)).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: MAGNIFY_POST,
    });
  });

  it("2609.0003 S6: a forged reveal cannot flip a magnify card's mode or add a console line", () => {
    expect(readyActions("magnify", "reveal")).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: MAGNIFY_POST,
    });
  });

  it("2609.0003 S7: a forged magnify cannot inject root zoom into a reveal card", () => {
    // The in-force invariant: a repeat decides from the mode already adopted,
    // never from its own meta. Deciding from `declared` here would hand a reveal
    // document a root zoom of K and break its layout outright.
    expect(readyActions("reveal", "magnify")).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: null,
    });
  });

  it("2609.0003 S7: a reveal card's honest repeat is equally silent", () => {
    expect(readyActions("reveal", "reveal")).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: null,
    });
  });

  it("2609.0003 S7: and a reveal card's meta-less repeat — the last cell of the table", () => {
    // Completes the inForce x meta grid: without this, "reveal in force" is only
    // ever exercised with a meta present.
    expect(readyActions("reveal", null)).toEqual({
      adopt: null,
      logLine: null,
      zoomPost: null,
    });
  });
});
