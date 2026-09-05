// Gate tests for the SHIPPED card_shim.js (spec 2609.0002, scenarios S5-S28 and
// S40).
//
// These read `desktop/src-tauri/src/card_shim.js` off disk and evaluate it in a
// Node `vm` against fake schedulers, so what is asserted is the exact text that
// `card_protocol.rs` include_str!s into every tarmac-card:// response — not a
// copy that could drift. Precedent: kit-build.test.ts, which reads a shipped
// build artefact rather than duplicating it.
//
// Two harness rules make the assertions mean anything:
//
//   * All six scheduler natives are installed on the fake window BEFORE the
//     shim's IIFE runs. The shim captures them at load, so a late install would
//     hand it different functions than the suite observes.
//   * Native ids come from disjoint per-family ranges well above any plausible
//     shim counter (1000/2000/3000 against a shim starting at 1). Without this,
//     "the native was called with the NATIVE id" is indistinguishable from a
//     wrapper passing its own id through, and S7/S40 go vacuous.
//
// "The card calls X" is always spelled `h.win.X(...)` — the wrappers are
// installed onto `window`, and going through it is what makes S6 (which
// reference does resume use?) assertable.

import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const SHIM_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "src-tauri",
  "src",
  "card_shim.js",
);
const SHIM_SOURCE = fs.readFileSync(SHIM_PATH, "utf8");

const RAF_ID_BASE = 1000;
const TIMEOUT_ID_BASE = 2000;
const INTERVAL_ID_BASE = 3000;

type Fn = (...args: any[]) => unknown;

interface Harness {
  win: any;
  posted: any[];
  style: Record<string, unknown>;
  calls: {
    requestAnimationFrame: number[];
    cancelAnimationFrame: number[];
    setTimeout: Array<{ id: number; delay: unknown; args: unknown[] }>;
    clearTimeout: number[];
    setInterval: Array<{ id: number; delay: unknown }>;
    clearInterval: number[];
  };
  /** Deliver a host postMessage (default source: window.parent). */
  send(data: unknown, source?: unknown): void;
  fire(type: string, event: unknown): void;
  domReady(): void;
  /** Run every outstanding native frame callback with `ts`. */
  driveFrame(ts: number): void;
  /** Fire one pending native timeout by its native id. */
  fireTimeout(id: number): void;
  /** Fire every pending native timeout, oldest id first. */
  drainTimeouts(): void;
  /** Tick one native interval by its native id (the timer stays armed). */
  tickInterval(id: number): void;
  pendingFrameIds(): number[];
  pendingTimeoutIds(): number[];
}

function loadShim(meta: string | null = "magnify", omitNative?: string): Harness {
  const listeners = new Map<string, Fn[]>();
  const docListeners = new Map<string, Fn[]>();
  const posted: any[] = [];

  const frames = new Map<number, Fn>();
  const timeouts = new Map<number, { cb: Fn; args: unknown[] }>();
  const intervals = new Map<number, Fn>();

  let rafSeq = RAF_ID_BASE;
  let timeoutSeq = TIMEOUT_ID_BASE;
  let intervalSeq = INTERVAL_ID_BASE;

  const calls: Harness["calls"] = {
    requestAnimationFrame: [],
    cancelAnimationFrame: [],
    setTimeout: [],
    clearTimeout: [],
    setInterval: [],
    clearInterval: [],
  };

  const parent = {
    postMessage(data: unknown) {
      posted.push(data);
    },
  };

  const style: Record<string, unknown> = {};

  const add = (map: Map<string, Fn[]>, type: string, fn: Fn) => {
    const arr = map.get(type) ?? [];
    arr.push(fn);
    map.set(type, arr);
  };

  const win: any = {
    parent,
    addEventListener: (type: string, fn: Fn) => add(listeners, type, fn),
    removeEventListener: () => {},
    scrollBy: () => {},

    requestAnimationFrame(cb: Fn) {
      const id = rafSeq++;
      frames.set(id, cb);
      calls.requestAnimationFrame.push(id);
      return id;
    },
    cancelAnimationFrame(id: number) {
      calls.cancelAnimationFrame.push(id);
      frames.delete(id);
    },
    setTimeout(cb: Fn, delay: unknown, ...args: unknown[]) {
      const id = timeoutSeq++;
      timeouts.set(id, { cb, args });
      calls.setTimeout.push({ id, delay, args });
      return id;
    },
    clearTimeout(id: number) {
      calls.clearTimeout.push(id);
      timeouts.delete(id);
    },
    setInterval(cb: Fn, delay: unknown) {
      const id = intervalSeq++;
      intervals.set(id, cb);
      calls.setInterval.push({ id, delay });
      return id;
    },
    clearInterval(id: number) {
      calls.clearInterval.push(id);
      intervals.delete(id);
    },

    console: {
      log: () => {},
      info: () => {},
      warn: () => {},
      error: () => {},
    },

    document: {
      documentElement: { style },
      addEventListener: (type: string, fn: Fn) => add(docListeners, type, fn),
      querySelector(sel: string) {
        if (sel === 'meta[name="tarmac-zoom"]' && meta !== null) return { content: meta };
        return null;
      },
    },
  };
  win.window = win;
  // Used only by S5's negative control: prove the harness FAILS LOUDLY if a
  // native is missing when the shim captures, rather than silently handing the
  // suite a shim that captured undefined.
  if (omitNative) delete win[omitNative];

  vm.createContext(win);
  vm.runInContext(SHIM_SOURCE, win, { filename: "card_shim.js" });

  const emit = (map: Map<string, Fn[]>, type: string, event: unknown) => {
    for (const fn of map.get(type) ?? []) fn(event);
  };

  return {
    win,
    posted,
    style,
    calls,
    send: (data, source = parent) => emit(listeners, "message", { source, data }),
    fire: (type, event) => emit(listeners, type, event),
    domReady: () => emit(docListeners, "DOMContentLoaded", {}),
    driveFrame(ts) {
      const due = [...frames.entries()].sort((a, b) => a[0] - b[0]);
      frames.clear();
      for (const [, cb] of due) cb(ts);
    },
    fireTimeout(id) {
      const entry = timeouts.get(id);
      if (!entry) throw new Error(`no pending native timeout ${id}`);
      timeouts.delete(id);
      entry.cb(...entry.args);
    },
    drainTimeouts() {
      for (const id of [...timeouts.keys()].sort((a, b) => a - b)) {
        const entry = timeouts.get(id);
        if (!entry) continue;
        timeouts.delete(id);
        entry.cb(...entry.args);
      }
    },
    tickInterval(id) {
      const cb = intervals.get(id);
      if (!cb) throw new Error(`no armed native interval ${id}`);
      cb();
    },
    pendingFrameIds: () => [...frames.keys()],
    pendingTimeoutIds: () => [...timeouts.keys()],
  };
}

const pause = (h: Harness) => h.send({ tarmac: "cull", culled: true });
const resume = (h: Harness) => h.send({ tarmac: "cull", culled: false });

/** Resume and let both flush carriers run: the setTimeout(...,0) hop, then the
 *  catch-up frame. Mirrors what an engine does after the message returns. */
function resumeAndDrain(h: Harness, ts = 1) {
  resume(h);
  h.drainTimeouts();
  h.driveFrame(ts);
}

// --------------------------------------------------------------------------
// Harness preconditions
// --------------------------------------------------------------------------

describe("harness precondition: the shipped shim loads and still handshakes (S5)", () => {
  it("posts ready with the document's own meta and applies a host zoom", () => {
    const h = loadShim("magnify");

    h.domReady();
    expect(h.posted).toContainEqual({ tarmac: "ready", meta: "magnify" });

    h.send({ tarmac: "zoom", z: 3 });
    expect(h.style.zoom).toBe(3);
  });

  it("reports a null meta for a document with no tarmac-zoom tag", () => {
    const h = loadShim(null);
    h.domReady();
    expect(h.posted).toContainEqual({ tarmac: "ready", meta: null });
  });

  it("fails loudly if a scheduler native is missing when the shim captures", () => {
    // The precondition that matters is that the natives exist BEFORE the IIFE,
    // so the shim captures the same functions the suite observes. Asserting
    // typeof after load would only re-check the shim's own wrappers. This
    // asserts the harness cannot silently hand the suite a shim that captured
    // undefined — which is how every other [S] scenario would go vacuous.
    for (const name of [
      "requestAnimationFrame",
      "cancelAnimationFrame",
      "setTimeout",
      "clearTimeout",
      "setInterval",
    ]) {
      expect(() => loadShim("magnify", name)).toThrow();
    }
  });
});

describe("the gate uses the natives captured at load, not the current globals (S6)", () => {
  it("cancels and resumes through captured references after a card replaces them", () => {
    const h = loadShim();
    const ran: string[] = [];

    // Issued BEFORE the globals are replaced: once replaced, card code can no
    // longer reach the wrappers at all, so the callbacks under test must predate it.
    h.win.requestAnimationFrame(() => ran.push("frame"));
    const timeoutId = h.win.setTimeout(() => ran.push("timeout"), 5);
    const nativeFrameId = h.calls.requestAnimationFrame[0];

    const boom = () => {
      throw new Error("card replaced a scheduler global");
    };
    h.win.requestAnimationFrame = boom;
    h.win.setTimeout = boom;
    h.win.cancelAnimationFrame = boom;

    pause(h);
    expect(h.calls.cancelAnimationFrame).toContain(nativeFrameId);

    h.fireTimeout(timeoutId);
    expect(ran).toEqual([]);

    resumeAndDrain(h);
    expect(ran.sort()).toEqual(["frame", "timeout"]);
  });
});

// --------------------------------------------------------------------------
// requestAnimationFrame
// --------------------------------------------------------------------------

describe("requestAnimationFrame gate (S7-S11)", () => {
  it("S7: pause calls the NATIVE cancelAnimationFrame with the outstanding native id", () => {
    const h = loadShim();
    let ran = false;

    h.win.requestAnimationFrame(() => {
      ran = true;
    });
    const nativeId = h.calls.requestAnimationFrame[0];
    expect(nativeId).toBeGreaterThanOrEqual(RAF_ID_BASE);

    pause(h);

    expect(h.calls.cancelAnimationFrame).toEqual([nativeId]);
    expect(h.pendingFrameIds()).toEqual([]);
    expect(ran).toBe(false);
  });

  it("S8: a paused rAF call reaches no native and still returns a usable id", () => {
    const h = loadShim();
    pause(h);
    const before = h.calls.requestAnimationFrame.length;

    const a = h.win.requestAnimationFrame(() => {});
    const b = h.win.requestAnimationFrame(() => {});

    expect(h.calls.requestAnimationFrame.length).toBe(before);
    expect(a).toBeDefined();
    expect(b).toBeDefined();
    expect(a).not.toBe(b);
  });

  it("S9: resume issues exactly one native frame and delivers all held callbacks once, in order", () => {
    const h = loadShim();
    const ran: string[] = [];

    h.win.requestAnimationFrame(() => ran.push("pre"));
    pause(h);
    h.win.requestAnimationFrame(() => ran.push("mid"));
    h.win.requestAnimationFrame(() => ran.push("post"));

    const nativeCallsBefore = h.calls.requestAnimationFrame.length;
    resume(h);
    expect(h.calls.requestAnimationFrame.length).toBe(nativeCallsBefore + 1);

    h.driveFrame(1);
    expect(ran).toEqual(["pre", "mid", "post"]);
  });

  it("S10: cancelAnimationFrame on a held id drops only that callback", () => {
    const h = loadShim();
    const ran: string[] = [];

    pause(h);
    const doomed = h.win.requestAnimationFrame(() => ran.push("doomed"));
    h.win.requestAnimationFrame(() => ran.push("kept"));

    h.win.cancelAnimationFrame(doomed);
    resumeAndDrain(h);

    expect(ran).toEqual(["kept"]);
  });

  it("S11: a re-issued callback receives the fresh catch-up timestamp", () => {
    const h = loadShim();
    const seen: number[] = [];

    h.win.requestAnimationFrame((ts: number) => seen.push(ts));
    pause(h);
    resume(h);
    h.driveFrame(987); // distinct from any pre-pause timestamp

    expect(seen).toEqual([987]);
  });
});

// --------------------------------------------------------------------------
// setInterval
// --------------------------------------------------------------------------

describe("setInterval gate (S12-S14)", () => {
  it("S12: a paused interval delivers nothing while the native keeps ticking", () => {
    const h = loadShim();
    let ticks = 0;

    h.win.setInterval(() => {
      ticks++;
    }, 16);
    const nativeId = h.calls.setInterval[0].id;
    expect(nativeId).toBeGreaterThanOrEqual(INTERVAL_ID_BASE);

    pause(h);
    h.tickInterval(nativeId);
    h.tickInterval(nativeId);
    h.tickInterval(nativeId);

    expect(ticks).toBe(0);
    expect(h.calls.clearInterval).not.toContain(nativeId);
  });

  it("S13: missed ticks are dropped, not flushed on resume", () => {
    const h = loadShim();
    let ticks = 0;

    h.win.setInterval(() => {
      ticks++;
    }, 16);
    const nativeId = h.calls.setInterval[0].id;

    pause(h);
    h.tickInterval(nativeId);
    h.tickInterval(nativeId);
    h.tickInterval(nativeId);

    resumeAndDrain(h);
    expect(ticks).toBe(0); // the resume itself delivers nothing

    h.tickInterval(nativeId);
    expect(ticks).toBe(1); // one, not three
  });

  it("S14: clearInterval while paused reaches the native and ends the interval", () => {
    const h = loadShim();
    let ticks = 0;

    const id = h.win.setInterval(() => {
      ticks++;
    }, 16);
    const nativeId = h.calls.setInterval[0].id;

    pause(h);
    h.win.clearInterval(id);
    expect(h.calls.clearInterval).toContain(nativeId);

    resumeAndDrain(h);
    expect(ticks).toBe(0);
    expect(() => h.tickInterval(nativeId)).toThrow(); // disarmed natively
  });
});

// --------------------------------------------------------------------------
// setTimeout
// --------------------------------------------------------------------------

describe("setTimeout gate (S15-S20)", () => {
  it("S15: a timeout whose native timer fires DURING the pause is diverted, not run", () => {
    const h = loadShim();
    let ran = false;

    // Issued while running — a call-time gate would let this one through.
    const id = h.win.setTimeout(() => {
      ran = true;
    }, 16);

    pause(h);
    h.fireTimeout(id);

    expect(ran).toBe(false);
  });

  it("S16: resume flushes it exactly once, through a native setTimeout(...,0) hop", () => {
    const h = loadShim();
    let runs = 0;

    const id = h.win.setTimeout(() => {
      runs++;
    }, 16);
    pause(h);
    h.fireTimeout(id);

    const before = h.calls.setTimeout.length;
    resume(h);

    // Not re-entrant: nothing has run by the time the message listener returns.
    expect(runs).toBe(0);
    const hop = h.calls.setTimeout[before];
    expect(hop).toBeDefined();
    expect(hop.delay).toBe(0);

    h.drainTimeouts();
    expect(runs).toBe(1);

    h.drainTimeouts();
    expect(runs).toBe(1); // and only once
  });

  it("S17: extra arguments survive the divert and the flush", () => {
    const h = loadShim();
    const seen: unknown[][] = [];

    const id = h.win.setTimeout((...args: unknown[]) => seen.push(args), 16, "a", 7);
    pause(h);
    h.fireTimeout(id);
    resumeAndDrain(h);

    expect(seen).toEqual([["a", 7]]);
  });

  it("S18: clearTimeout on a diverted callback stops it running at any point", () => {
    const h = loadShim();
    let ran = false;

    const id = h.win.setTimeout(() => {
      ran = true;
    }, 16);
    pause(h);
    h.fireTimeout(id);
    expect(ran).toBe(false); // not during the pause either

    h.win.clearTimeout(id);
    resumeAndDrain(h);

    expect(ran).toBe(false);
  });

  it("S19: a timeout issued while paused arms the native immediately with its own delay", () => {
    const h = loadShim();
    pause(h);
    const before = h.calls.setTimeout.length;

    h.win.setTimeout(() => {}, 5000);

    const armed = h.calls.setTimeout[before];
    expect(armed).toBeDefined();
    expect(armed.delay).toBe(5000);
  });

  it("S20: both families flush in issue order within each family", () => {
    const h = loadShim();
    const ran: string[] = [];

    const a = h.win.setTimeout(() => ran.push("tA"), 16);
    const b = h.win.setTimeout(() => ran.push("tB"), 16);
    h.win.requestAnimationFrame(() => ran.push("fX"));

    pause(h);
    h.fireTimeout(a);
    h.fireTimeout(b);
    h.win.requestAnimationFrame(() => ran.push("fY"));
    h.win.requestAnimationFrame(() => ran.push("fZ"));

    resumeAndDrain(h);

    expect(ran.filter((n) => n.startsWith("t"))).toEqual(["tA", "tB"]);
    expect(ran.filter((n) => n.startsWith("f"))).toEqual(["fX", "fY", "fZ"]);
    // No interleaving under this drain order — which is what a single shared
    // queue would produce. Cross-family ordering itself is an engine property
    // (S38, QA), not a promise of the shim.
    expect(ran).toEqual(["tA", "tB", "fX", "fY", "fZ"]);
  });

  it("S21: each family is carried by its own captured native primitive", () => {
    const h = loadShim();

    const t = h.win.setTimeout(() => {}, 16);
    h.win.requestAnimationFrame(() => {});
    pause(h);
    h.fireTimeout(t);

    const timeoutsBefore = h.calls.setTimeout.length;
    const framesBefore = h.calls.requestAnimationFrame.length;
    resume(h);

    expect(h.calls.setTimeout.length).toBe(timeoutsBefore + 1);
    expect(h.calls.setTimeout[timeoutsBefore].delay).toBe(0);
    expect(h.calls.requestAnimationFrame.length).toBe(framesBefore + 1);
  });
});

// --------------------------------------------------------------------------
// Idempotence, re-pause, load ordering
// --------------------------------------------------------------------------

describe("idempotence and re-pause (S22-S25)", () => {
  it("S22: a repeat pause re-cancels nothing and does not duplicate deliveries", () => {
    const h = loadShim();
    const ran: string[] = [];

    h.win.requestAnimationFrame(() => ran.push("frame"));
    const t = h.win.setTimeout(() => ran.push("timeout"), 16);

    pause(h);
    h.fireTimeout(t);
    const cancelsAfterFirstPause = [...h.calls.cancelAnimationFrame];

    pause(h);
    pause(h);
    expect(h.calls.cancelAnimationFrame).toEqual(cancelsAfterFirstPause);

    resumeAndDrain(h);
    expect(ran).toEqual(["timeout", "frame"]);
  });

  it("S23: a resume while running touches nothing the card already has in flight", () => {
    const h = loadShim();
    const ran: string[] = [];

    // The fixture that matters: LIVE, outstanding work at the moment the
    // redundant resume arrives. A resume that skips its own early-out would
    // sweep these into a catch-up flush — delivering them early here and again
    // when their real native timers fire.
    h.win.requestAnimationFrame(() => ran.push("frame"));
    const t = h.win.setTimeout(() => ran.push("timeout"), 16);

    const framesBefore = h.calls.requestAnimationFrame.length;
    const timeoutsBefore = h.calls.setTimeout.length;
    resume(h);

    expect(h.calls.requestAnimationFrame.length).toBe(framesBefore);
    expect(h.calls.setTimeout.length).toBe(timeoutsBefore);
    expect(ran).toEqual([]);

    // And they still run exactly once, on their own native fires.
    h.driveFrame(1);
    h.fireTimeout(t);
    expect(ran).toEqual(["frame", "timeout"]);

    h.driveFrame(2);
    h.drainTimeouts();
    expect(ran).toEqual(["frame", "timeout"]);
  });

  it("S24: a re-pause during the flush re-holds BOTH families and loses neither", () => {
    const h = loadShim();
    const ran: string[] = [];

    h.win.requestAnimationFrame(() => ran.push("frame"));
    const nativeFrameId = h.calls.requestAnimationFrame[0];
    const t = h.win.setTimeout(() => ran.push("timeout"), 16);
    pause(h);
    h.fireTimeout(t);

    // Resume schedules the hop and the catch-up frame, then a cull arrives
    // before either fires.
    resume(h);
    const catchUpId = h.calls.requestAnimationFrame[h.calls.requestAnimationFrame.length - 1];
    pause(h);
    // toEqual, not toContain: the exact cancel list is the assertion. The first
    // pause retired the card's own request, the second retires the catch-up —
    // and nothing is cancelled twice, which is the "must not re-cancel" half of
    // idempotence (a stale nativeId left behind would show up as a repeat).
    expect(h.calls.cancelAnimationFrame).toEqual([nativeFrameId, catchUpId]);

    h.drainTimeouts();
    h.driveFrame(1);
    expect(ran).toEqual([]); // re-diverted, not run while paused

    resumeAndDrain(h, 2);
    expect(ran).toEqual(["timeout", "frame"]); // and each exactly once
  });

  it("S25: a cull arriving before DOMContentLoaded still pauses", () => {
    const h = loadShim();

    pause(h); // no domReady() yet — no ready posted
    expect(h.posted.some((m) => m && m.tarmac === "ready")).toBe(false);

    const before = h.calls.requestAnimationFrame.length;
    h.win.requestAnimationFrame(() => {});

    expect(h.calls.requestAnimationFrame.length).toBe(before);
  });
});

describe("a delivered callback is never delivered again (S41)", () => {
  // Every other exactly-once assertion stops after ONE pause->resume round trip.
  // A board culls and un-culls a card constantly as the user pans, and three
  // separate one-line breaks — failing to drop an entry after a natural frame,
  // after a catch-up flush, or after a timeout flush — leave spent callbacks in
  // the held queues, where each later un-cull re-delivers them. That is the
  // frame storm pinned semantic 3 forbids, and it is invisible inside one trip.

  it("a frame delivered naturally is not re-delivered by a later round trip", () => {
    const h = loadShim();
    const ran: string[] = [];

    h.win.requestAnimationFrame(() => ran.push("frame"));
    h.driveFrame(1); // delivered normally, while running
    expect(ran).toEqual(["frame"]);

    pause(h);
    resumeAndDrain(h, 2);
    expect(ran).toEqual(["frame"]);
  });

  it("a frame delivered by a catch-up flush is not re-delivered by the next one", () => {
    const h = loadShim();
    const ran: string[] = [];

    pause(h);
    h.win.requestAnimationFrame(() => ran.push("frame"));
    resumeAndDrain(h, 1);
    expect(ran).toEqual(["frame"]);

    pause(h);
    resumeAndDrain(h, 2);
    expect(ran).toEqual(["frame"]);
  });

  it("a timeout delivered by a flush is not re-delivered by the next one", () => {
    const h = loadShim();
    const ran: string[] = [];

    const t = h.win.setTimeout(() => ran.push("timeout"), 16);
    pause(h);
    h.fireTimeout(t);
    resumeAndDrain(h, 1);
    expect(ran).toEqual(["timeout"]);

    pause(h);
    resumeAndDrain(h, 2);
    expect(ran).toEqual(["timeout"]);
  });

  it("survives several round trips over both families at once", () => {
    const h = loadShim();
    const ran: string[] = [];

    h.win.requestAnimationFrame(() => ran.push("frame"));
    const nativeFrameId = h.calls.requestAnimationFrame[0];
    const nativeTimeoutId = h.calls.setTimeout.length;
    const t = h.win.setTimeout(() => ran.push("timeout"), 16);
    pause(h);
    h.fireTimeout(t);

    for (let i = 1; i <= 4; i++) {
      resumeAndDrain(h, i);
      pause(h);
    }
    resumeAndDrain(h, 5);

    expect(ran).toEqual(["timeout", "frame"]);

    // Once the queues have drained, later round trips must be FREE. Exactly one
    // catch-up frame and one flush hop were ever needed — the first resume's.
    // A resume that schedules a catch-up (or a hop) with nothing to flush leaves
    // a pending native request behind on every un-cull, which is the standing
    // charge this whole feature exists to remove.
    expect(h.calls.requestAnimationFrame.length).toBe(2); // the card's + one catch-up
    expect(h.calls.setTimeout.length).toBe(nativeTimeoutId + 2); // the card's + one hop

    // And nothing is cancelled twice: a spent catch-up id must not be retained
    // and re-cancelled by the next pause.
    expect(h.calls.cancelAnimationFrame).toEqual([nativeFrameId]);
  });
});

describe("a throwing flushed callback is isolated and reported (S42)", () => {
  it("does not strand the rest of the queue, in either family", () => {
    const h = loadShim();
    const ran: string[] = [];

    // A throwing callback in the MIDDLE of each queue: the ones issued after it
    // must still be delivered. The native schedulers isolate callbacks by giving
    // each its own task; the flush runs them in one loop, so it has to isolate
    // them itself or one bad card callback silently drops the rest.
    const t1 = h.win.setTimeout(() => ran.push("t1"), 16);
    const t2 = h.win.setTimeout(() => {
      throw new Error("boom-timeout");
    }, 16);
    const t3 = h.win.setTimeout(() => ran.push("t3"), 16);
    pause(h);
    h.fireTimeout(t1);
    h.fireTimeout(t2);
    h.fireTimeout(t3);

    h.win.requestAnimationFrame(() => ran.push("f1"));
    h.win.requestAnimationFrame(() => {
      throw new Error("boom-frame");
    });
    h.win.requestAnimationFrame(() => ran.push("f3"));

    resumeAndDrain(h);

    expect(ran).toEqual(["t1", "t3", "f1", "f3"]);
  });

  it("relays the exception rather than swallowing it", () => {
    const h = loadShim();

    const t = h.win.setTimeout(() => {
      throw new Error("boom-timeout");
    }, 16);
    pause(h);
    h.fireTimeout(t);
    resumeAndDrain(h);

    // The live path lets a throw reach window.onerror and the error relay, so
    // swallowing it here would make a card's exception vanish precisely when the
    // callback happened to be flushed after a cull.
    expect(h.posted).toContainEqual({
      tarmac: "console",
      level: "error",
      args: ["boom-timeout"],
    });
  });
});

describe("the never-paused path stays transparent (S40)", () => {
  it("forwards every cancel to its captured native and runs nothing", () => {
    const h = loadShim();
    const ran: string[] = [];

    const frame = h.win.requestAnimationFrame(() => ran.push("frame"));
    const timeout = h.win.setTimeout(() => ran.push("timeout"), 16);
    const interval = h.win.setInterval(() => ran.push("interval"), 16);

    const nativeFrame = h.calls.requestAnimationFrame[0];
    const nativeTimeout = h.calls.setTimeout[0].id;
    const nativeInterval = h.calls.setInterval[0].id;

    h.win.cancelAnimationFrame(frame);
    h.win.clearTimeout(timeout);
    h.win.clearInterval(interval);

    expect(h.calls.cancelAnimationFrame).toEqual([nativeFrame]);
    expect(h.calls.clearTimeout).toEqual([nativeTimeout]);
    expect(h.calls.clearInterval).toEqual([nativeInterval]);

    h.driveFrame(1);
    h.drainTimeouts();
    expect(ran).toEqual([]);
  });
});

// --------------------------------------------------------------------------
// Never gated / hostile input
// --------------------------------------------------------------------------

describe("relays are never gated (S26)", () => {
  it("a paused card can still report console, errors, rejections and escape", () => {
    const h = loadShim();
    pause(h);

    h.win.console.log("x");
    h.fire("error", { message: "boom" });
    h.fire("unhandledrejection", { reason: "nope" });
    h.fire("keydown", { key: "Escape" });

    expect(h.posted).toContainEqual({ tarmac: "console", level: "log", args: ["x"] });
    expect(h.posted).toContainEqual({ tarmac: "console", level: "error", args: ["boom"] });
    expect(h.posted).toContainEqual({ tarmac: "console", level: "error", args: ["nope"] });
    expect(h.posted).toContainEqual({ tarmac: "escape" });
  });

  it("ready still posts while paused — it is what carries the born-culled state", () => {
    const h = loadShim();
    pause(h);
    h.domReady();
    expect(h.posted).toContainEqual({ tarmac: "ready", meta: "magnify" });
  });
});

describe("hostile and malformed cull messages (S27, S28)", () => {
  const stillRunning = (h: Harness) => {
    const before = h.calls.requestAnimationFrame.length;
    h.win.requestAnimationFrame(() => {});
    return h.calls.requestAnimationFrame.length === before + 1;
  };
  const stillPaused = (h: Harness) => !stillRunning(h);

  it("S27: a cull from any source other than window.parent is ignored", () => {
    const h = loadShim();
    h.send({ tarmac: "cull", culled: true }, { not: "parent" });
    expect(stillRunning(h)).toBe(true);
  });

  it("S28: a malformed cull leaves the gate state unchanged, from either state", () => {
    const running = loadShim();
    running.send({ tarmac: "cull" });
    expect(stillRunning(running)).toBe(true);
    running.send({ tarmac: "cull", culled: "true" });
    expect(stillRunning(running)).toBe(true);

    // The load-bearing half: from PAUSED, a naive `paused = !!d.culled` would
    // silently un-pause on the missing-key message.
    const paused0 = loadShim();
    pause(paused0);
    paused0.send({ tarmac: "cull" });
    expect(stillPaused(paused0)).toBe(true);
    paused0.send({ tarmac: "cull", culled: "true" });
    expect(stillPaused(paused0)).toBe(true);
  });

  it("S28: the relays still work after a malformed cull", () => {
    const h = loadShim();
    h.send({ tarmac: "cull", culled: {} });
    h.win.console.log("alive");
    expect(h.posted).toContainEqual({ tarmac: "console", level: "log", args: ["alive"] });
  });
});
