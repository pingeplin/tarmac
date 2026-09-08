// Tests for the host-page rAF counter (#105). The instrument's whole value is
// that its reading can be trusted where a CPU band cannot, so what is pinned
// here is the count's arithmetic under every way it can be corrupted: a frame
// that fires, a cancel, a repeat cancel, a foreign id, a throwing callback, the
// self-rescheduling loop that never lets the count reach 0, and a second
// install wrapping the first.

import { describe, it, expect, vi } from "vitest";
import {
  createRafCounter,
  formatSummary,
  installRafProbe,
  sampleOutstanding,
  summarize,
  type ProbeGlobal,
  type RafCounter,
} from "./rafProbe";

/** A hand-pumped rAF engine: `frame()` delivers exactly the requests standing
 * at that moment, which is what the platform does. */
function fakeRafHost() {
  let seq = 0;
  const pending = new Map<number, FrameRequestCallback>();
  const cancelled: number[] = [];
  return {
    requestAnimationFrame(cb: FrameRequestCallback): number {
      const id = ++seq;
      pending.set(id, cb);
      return id;
    },
    cancelAnimationFrame(handle: number): void {
      cancelled.push(handle);
      pending.delete(handle);
    },
    frame(ts = 0): void {
      const due = [...pending.entries()];
      pending.clear();
      for (const [, cb] of due) cb(ts);
    },
    cancelled,
  };
}

/** A hand-pumped interval engine. `tick()` runs one period for every armed
 * interval; a cleared one stops. */
function fakeTimerHost() {
  let seq = 0;
  const armed = new Map<number, () => void>();
  const periods = new Map<number, number>();
  return {
    setInterval(cb: () => void, ms: number): number {
      const id = ++seq;
      armed.set(id, cb);
      periods.set(id, ms);
      return id;
    },
    clearInterval(handle: number): void {
      armed.delete(handle);
    },
    tick(times = 1): void {
      for (let i = 0; i < times; i++) for (const cb of [...armed.values()]) cb();
    },
    armedCount: () => armed.size,
    periodOf: (id: number) => periods.get(id),
  };
}

const counterOn = (host: ReturnType<typeof fakeRafHost>, now = () => 0): RafCounter =>
  createRafCounter(host, now);

describe("outstanding count", () => {
  it("rises on a request and falls when the frame is delivered", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    expect(c.outstanding()).toBe(0);
    c.raf(() => {});
    expect(c.outstanding()).toBe(1);
    host.frame();
    expect(c.outstanding()).toBe(0);
  });

  it("counts concurrent requests independently", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    const a = c.raf(() => {});
    c.raf(() => {});
    expect(c.outstanding()).toBe(2);
    c.cancel(a);
    expect(c.outstanding()).toBe(1);
    host.frame();
    expect(c.outstanding()).toBe(0);
  });

  it("passes the frame timestamp and the native id through", () => {
    const host = fakeRafHost();
    const c = counterOn(host);
    const cb = vi.fn();

    const id = c.raf(cb);
    host.frame(123.5);

    expect(cb).toHaveBeenCalledWith(123.5);
    // The native id, not one of our own: `cancel(id)` from code that never saw
    // this wrapper must still reach the platform.
    expect(id).toBe(1);
  });

  it("cancels at the native and stops counting the request", () => {
    const host = fakeRafHost();
    const c = counterOn(host);
    const cb = vi.fn();

    const id = c.raf(cb);
    c.cancel(id);

    expect(host.cancelled).toEqual([id]);
    expect(c.outstanding()).toBe(0);
    host.frame();
    expect(cb).not.toHaveBeenCalled();
  });

  it("does not decrement twice when the same id is cancelled twice", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    const a = c.raf(() => {});
    c.raf(() => {});
    c.cancel(a);
    c.cancel(a);

    // A naive counter reads 0 here and would report an idle page mid-animation.
    expect(c.outstanding()).toBe(1);
  });

  it("does not decrement on a cancel of an id that already fired", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    const a = c.raf(() => {});
    host.frame();
    c.raf(() => {});
    c.cancel(a);

    expect(c.outstanding()).toBe(1);
  });

  it("forwards a foreign id to the native cancel without touching the count", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    c.raf(() => {});
    c.cancel(9999);

    expect(host.cancelled).toEqual([9999]);
    expect(c.outstanding()).toBe(1);
  });

  it("retires the request even when the callback throws", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    c.raf(() => {
      throw new Error("card code");
    });
    expect(() => host.frame()).toThrow("card code");

    // Swallowing the throw would hide a real error; leaking the count would
    // make the page look permanently busy.
    expect(c.outstanding()).toBe(0);
  });

  it("reads 1 across every frame of a self-rescheduling loop", () => {
    const host = fakeRafHost();
    const c = counterOn(host);
    const loop = () => {
      c.raf(loop);
    };

    loop();
    for (let i = 0; i < 5; i++) {
      expect(c.outstanding()).toBe(1);
      host.frame();
    }
    // The shape the regime question is about: an animation loop never lets the
    // count fall to 0 between frames.
    expect(c.outstanding()).toBe(1);
  });
});

describe("transition log", () => {
  it("stamps every change with the host clock", () => {
    const host = fakeRafHost();
    let t = 0;
    const c = createRafCounter(host, () => (t += 10));

    c.raf(() => {});
    host.frame();

    expect(c.transitions()).toEqual([
      { t: 10, n: 1 },
      { t: 20, n: 0 },
    ]);
  });

  it("keeps the tail, so the reading after a long pan is still the recent one", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    for (let i = 0; i < 300; i++) c.raf(() => {});
    const log = c.transitions();

    expect(log.length).toBe(256);
    expect(log[log.length - 1].n).toBe(300);
    expect(log[0].n).toBe(45); // 300 - 256 + 1
  });

  it("hands out a copy, so a reader cannot corrupt the log", () => {
    const host = fakeRafHost();
    const c = counterOn(host);

    c.raf(() => {});
    c.transitions().length = 0;

    expect(c.transitions().length).toBe(1);
  });
});

describe("summarize", () => {
  it("scores 190 zeros in 200 samples at exactly the 95% bar", () => {
    const series = [...Array(190).fill(0), ...Array(10).fill(1)];
    expect(summarize(series)).toEqual({
      samples: 200,
      zeros: 190,
      zeroFraction: 0.95,
      max: 1,
    });
  });

  it("reports the peak, not just the zero share", () => {
    expect(summarize([0, 3, 1, 0]).max).toBe(3);
  });

  it("returns 0, not NaN, for an empty series", () => {
    expect(summarize([])).toEqual({ samples: 0, zeros: 0, zeroFraction: 0, max: 0 });
  });
});

describe("sampleOutstanding", () => {
  it("takes duration x hz samples, then disarms its timer", async () => {
    const host = fakeRafHost();
    const timers = fakeTimerHost();
    const c = counterOn(host);

    const done = sampleOutstanding(c, timers, 1000, 20);
    expect(timers.periodOf(1)).toBe(50);
    timers.tick(20);
    const r = await done;

    expect(r.samples).toBe(20);
    expect(r.hz).toBe(20);
    expect(r.durationMs).toBe(1000);
    expect(timers.armedCount()).toBe(0);
  });

  it("records the outstanding count at each tick, not a summary of frames", async () => {
    const host = fakeRafHost();
    const timers = fakeTimerHost();
    const c = counterOn(host);

    const done = sampleOutstanding(c, timers, 200, 20);
    timers.tick(); // 0
    c.raf(() => {});
    timers.tick(2); // 1, 1
    host.frame();
    timers.tick(); // 0
    const r = await done;

    expect(r.series).toEqual([0, 1, 1, 0]);
    expect(r.zeroFraction).toBe(0.5);
    expect(r.transitions.length).toBe(2);
  });

  it("never samples fewer than one tick", async () => {
    const timers = fakeTimerHost();
    const c = counterOn(fakeRafHost());

    const done = sampleOutstanding(c, timers, 0, 20);
    timers.tick();

    expect((await done).samples).toBe(1);
  });
});

describe("formatSummary", () => {
  it("states the zero share and the peak", () => {
    expect(formatSummary({ samples: 200, zeros: 190, zeroFraction: 0.95, max: 2 })).toBe(
      "[tarmac raf] outstanding=0 in 190/200 samples (95.0%), max=2",
    );
  });
});

describe("installRafProbe", () => {
  function fakeGlobal() {
    const raf = fakeRafHost();
    const timers = fakeTimerHost();
    const win: ProbeGlobal & { frame: (ts?: number) => void; tick: (n?: number) => void } = {
      requestAnimationFrame: (cb) => raf.requestAnimationFrame(cb),
      cancelAnimationFrame: (h) => raf.cancelAnimationFrame(h),
      setInterval: (cb, ms) => timers.setInterval(cb, ms),
      clearInterval: (h) => timers.clearInterval(h),
      frame: (ts) => raf.frame(ts),
      tick: (n) => timers.tick(n),
    };
    return win;
  }

  it("exposes a live reading, not a stale snapshot", () => {
    const win = fakeGlobal();
    installRafProbe(win, () => {});

    expect(win.__tarmacRafOutstanding).toBe(0);
    win.requestAnimationFrame(() => {});
    expect(win.__tarmacRafOutstanding).toBe(1);
    win.frame();
    expect(win.__tarmacRafOutstanding).toBe(0);
  });

  it("counts requests made through the patched globals", async () => {
    const win = fakeGlobal();
    const lines: string[] = [];
    installRafProbe(win, (l) => lines.push(l));

    const done = win.__tarmacRafSample!(100, 20);
    win.requestAnimationFrame(() => {});
    win.tick(2);
    const r = await done;

    expect(r.series).toEqual([1, 1]);
    expect(lines).toEqual(["[tarmac raf] outstanding=0 in 0/2 samples (0.0%), max=1"]);
  });

  it("refuses a second install, so a request is never counted twice", () => {
    const win = fakeGlobal();
    installRafProbe(win, () => {});
    const again = installRafProbe(win, () => {});

    expect(again).toBeNull();
    win.requestAnimationFrame(() => {});
    expect(win.__tarmacRafOutstanding).toBe(1);
  });
});
