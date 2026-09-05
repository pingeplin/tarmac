// Tests for the host side of the culled-card scheduler gate (spec 2609.0002
// S1-S3): the polarity mapping, the payload's state-not-toggle shape, and the
// listener-map register/unregister rules.

import { describe, it, expect, vi } from "vitest";
import { cullMessage, registerCullListener, type CullListener } from "./cardCull";

describe("cullMessage polarity (2609.0002 S1)", () => {
  it("maps a culled card (visible=false) to culled:true", () => {
    expect(cullMessage(false)).toEqual({ tarmac: "cull", culled: true });
  });

  it("maps a visible card (visible=true) to culled:false", () => {
    expect(cullMessage(true)).toEqual({ tarmac: "cull", culled: false });
  });
});

describe("cullMessage is a state, not a toggle (2609.0002 S2)", () => {
  it("returns the same culled value for repeated identical inputs", () => {
    // A toggle passes S1 and fails here: its second call would invert.
    expect(cullMessage(false).culled).toBe(true);
    expect(cullMessage(false).culled).toBe(true);
    expect(cullMessage(false).culled).toBe(true);

    expect(cullMessage(true).culled).toBe(false);
    expect(cullMessage(true).culled).toBe(false);
  });

  it("depends only on its argument, not on call history", () => {
    cullMessage(false);
    cullMessage(false);
    cullMessage(true);
    expect(cullMessage(false)).toEqual({ tarmac: "cull", culled: true });
  });
});

describe("registerCullListener (2609.0002 S3)", () => {
  it("installs the listener and removes it on unregister", () => {
    const map = new Map<string, CullListener>();
    const fn = vi.fn();

    const off = registerCullListener(map, "a", fn);
    map.get("a")?.(true);
    expect(fn).toHaveBeenCalledWith(true);

    off();
    expect(map.has("a")).toBe(false);
  });

  it("is a no-op when the same unregister runs twice", () => {
    const map = new Map<string, CullListener>();
    const off = registerCullListener(map, "a", vi.fn());

    off();
    expect(() => off()).not.toThrow();
    expect(map.has("a")).toBe(false);
  });

  it("replaces the entry when the same id registers again", () => {
    const map = new Map<string, CullListener>();
    const first = vi.fn();
    const second = vi.fn();

    registerCullListener(map, "a", first);
    registerCullListener(map, "a", second);
    map.get("a")?.(true);

    expect(second).toHaveBeenCalledWith(true);
    expect(first).not.toHaveBeenCalled();
  });

  it("a stale unregister does not delete the listener that replaced it", () => {
    // React runs a remount's new effect BEFORE the old cleanup, so the stale
    // unregister always fires last. An unconditional delete would strand the card.
    const map = new Map<string, CullListener>();
    const first = vi.fn();
    const second = vi.fn();

    const offFirst = registerCullListener(map, "a", first);
    registerCullListener(map, "a", second);
    offFirst();

    expect(map.has("a")).toBe(true);
    map.get("a")?.(false);
    expect(second).toHaveBeenCalledWith(false);
  });

  it("unregisters only its own id", () => {
    const map = new Map<string, CullListener>();
    const a = vi.fn();
    const b = vi.fn();

    const offA = registerCullListener(map, "a", a);
    registerCullListener(map, "b", b);
    // Before, too: without this a register that wiped the map would satisfy the
    // "a is gone" assertion for the wrong reason, and only the last-mounted card
    // would ever be paused.
    expect(map.has("a")).toBe(true);
    expect(map.has("b")).toBe(true);

    offA();

    expect(map.has("a")).toBe(false);
    expect(map.has("b")).toBe(true);
  });
});
