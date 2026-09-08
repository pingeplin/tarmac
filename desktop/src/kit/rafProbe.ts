// Dev-only instrument (#105): how many `requestAnimationFrame` requests the
// HOST page is holding at any instant. Design 2609.0002 showed the culled-card
// residual is a per-page constant paid once by the page's first outstanding
// request, so whether Tarmac itself holds one while idle decides how much the
// cull gate recovers (~6 points if not, ~3 if the page is already rendering).
// That doc's own rule is that a CPU band proves nothing about the count — a
// focused WebGL terminal with zero outstanding requests still costs ~3 points —
// and `card_shim.js` cannot answer it either, since it lives in the iframe
// realm. Only a host-page counter can, which is what this is.
//
// Everything here is pure and takes its host by argument; `devRafProbe.ts`
// installs it on `window` behind the dev flag.

export interface RafHost {
  requestAnimationFrame(cb: FrameRequestCallback): number;
  cancelAnimationFrame(handle: number): void;
}

export interface TimerHost {
  setInterval(cb: () => void, ms: number): number;
  clearInterval(handle: number): void;
}

/** One change of the outstanding count, stamped with the host's clock. */
export interface Transition {
  t: number;
  n: number;
}

export interface RafCounter {
  raf(cb: FrameRequestCallback): number;
  cancel(handle: number): void;
  outstanding(): number;
  /** The tail of the transition log, oldest first. */
  transitions(): Transition[];
}

export interface Summary {
  samples: number;
  zeros: number;
  zeroFraction: number;
  max: number;
}

export interface SampleResult extends Summary {
  hz: number;
  durationMs: number;
  series: number[];
  transitions: Transition[];
}

/** Kept short on purpose: what a reader needs is the tail around a gesture's
 * end, not a whole pan. 256 covers ~2 s of 60 Hz churn. */
const TRANSITION_TAIL = 256;

export const DEFAULT_SAMPLE_MS = 10_000;
export const DEFAULT_SAMPLE_HZ = 20;

/**
 * Wraps `host`'s rAF pair with a live count of outstanding requests.
 *
 * Ids are the native ones — this counter never holds a callback, so unlike
 * `card_shim.js`'s gate it needs no id space of its own and a `cancel` of an id
 * we never issued still reaches the native.
 */
export function createRafCounter(host: RafHost, now: () => number): RafCounter {
  const nativeRaf = host.requestAnimationFrame.bind(host);
  const nativeCancel = host.cancelAnimationFrame.bind(host);
  // A set, not a counter: it makes every double-decrement impossible — a second
  // cancel, or a cancel of an id that already fired, is simply not a member.
  const live = new Set<number>();
  const log: Transition[] = [];

  function record() {
    log.push({ t: now(), n: live.size });
    if (log.length > TRANSITION_TAIL) log.shift();
  }

  function raf(cb: FrameRequestCallback): number {
    const id = nativeRaf((ts) => {
      // Retired before the callback runs, so a throwing callback cannot strand
      // the count at a phantom outstanding request.
      if (live.delete(id)) record();
      cb(ts);
    });
    live.add(id);
    record();
    return id;
  }

  function cancel(handle: number): void {
    if (live.delete(handle)) record();
    nativeCancel(handle);
  }

  return { raf, cancel, outstanding: () => live.size, transitions: () => log.slice() };
}

/** Zero-count statistics over a sample series. An empty series has no zeros and
 * no samples, so its fraction is 0 rather than NaN. */
export function summarize(series: number[]): Summary {
  const zeros = series.reduce((n, v) => (v === 0 ? n + 1 : n), 0);
  return {
    samples: series.length,
    zeros,
    zeroFraction: series.length === 0 ? 0 : zeros / series.length,
    max: series.reduce((m, v) => (v > m ? v : m), 0),
  };
}

/**
 * Samples `counter.outstanding()` at `hz` for `durationMs`.
 *
 * Timer-driven, never rAF-driven: a sampler that scheduled its own frame would
 * hold exactly the request it exists to detect. It writes no DOM either, so it
 * does not push the "idle" board it measures into rendering continuously.
 */
export function sampleOutstanding(
  counter: RafCounter,
  timers: TimerHost,
  durationMs: number = DEFAULT_SAMPLE_MS,
  hz: number = DEFAULT_SAMPLE_HZ,
): Promise<SampleResult> {
  const period = Math.max(1, Math.round(1000 / hz));
  const ticks = Math.max(1, Math.round(durationMs / period));
  const series: number[] = [];
  return new Promise((resolve) => {
    const handle = timers.setInterval(() => {
      series.push(counter.outstanding());
      if (series.length < ticks) return;
      timers.clearInterval(handle);
      resolve({
        ...summarize(series),
        hz,
        durationMs: ticks * period,
        series,
        transitions: counter.transitions(),
      });
    }, period);
  });
}

/** The one-line console verdict. `#105`'s bar is ≥ 95% zero samples. */
export function formatSummary(r: Summary): string {
  const pct = (r.zeroFraction * 100).toFixed(1);
  return `[tarmac raf] outstanding=0 in ${r.zeros}/${r.samples} samples (${pct}%), max=${r.max}`;
}

/** The window surface the probe installs onto — structural, so a test can pass
 * a plain object. */
export interface ProbeGlobal extends RafHost, TimerHost {
  __tarmacRafOutstanding?: number;
  __tarmacRafSample?: (durationMs?: number, hz?: number) => Promise<SampleResult>;
  __tarmacRafTransitions?: () => Transition[];
  performance?: { now(): number };
}

/**
 * Patches `win`'s rAF pair with a counting pass-through and exposes the reading
 * as `__tarmacRafOutstanding` (a live getter) plus `__tarmacRafSample()`.
 *
 * Returns the counter, or `null` if the probe was already installed — a second
 * install would wrap the first's wrappers and count every request twice.
 */
export function installRafProbe(
  win: ProbeGlobal,
  report: (line: string) => void = (line) => console.info(line),
): RafCounter | null {
  if (win.__tarmacRafSample) return null;
  const perf = win.performance;
  const counter = createRafCounter(win, perf ? () => perf.now() : () => Date.now());
  win.requestAnimationFrame = counter.raf;
  win.cancelAnimationFrame = counter.cancel;
  // A getter, so a console read is the count at that instant and the probe pays
  // nothing per transition to keep a plain property fresh.
  Object.defineProperty(win, "__tarmacRafOutstanding", {
    get: () => counter.outstanding(),
    configurable: true,
  });
  win.__tarmacRafSample = (durationMs, hz) =>
    sampleOutstanding(counter, win, durationMs, hz).then((r) => {
      report(formatSummary(r));
      return r;
    });
  win.__tarmacRafTransitions = () => counter.transitions();
  return counter;
}
