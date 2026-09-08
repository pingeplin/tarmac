# Host-page outstanding-rAF count — manual QA checklist (issue #105)

The regime question left open by design
[2609.0002](../../docs/designs/2609.0002_offscreen_html_card_throttle.md)
(§*Which regime is Tarmac in?*): the offscreen-card residual is a **per-page
constant** paid once by the page's first outstanding `requestAnimationFrame`
request, so how much the cull gate recovers depends on whether Tarmac's own UI
holds one while idle — ~6 points if it does not (*isolated*), ~3 if the page is
already rendering. That doc could only measure CPU bands, and its own rule is
that a CPU band proves nothing about the outstanding count: a focused WebGL
terminal with `cursorBlink:false` and **zero** outstanding requests still costs
~3 points. So "Tarmac is in the isolated regime" is recorded there as
*consistent with* the data, not established.

This sheet is the instrument that settles it. `src/kit/rafProbe.ts` counts the
**host page's** outstanding requests; `src/devRafProbe.ts` installs it, and
`main.tsx` imports that first so the wrappers are in place before any other
module body runs. The arithmetic is unit-tested (`src/kit/rafProbe.test.ts`);
what needs a human is the reading itself, because it takes the real app, a real
board and a real gesture.

## Status: NOT RUN

No reading has been taken. Until R1 and R2 below are run and recorded here,
`../../docs/architecture.md` keeps saying *consistent with isolated*, and no
document may upgrade it to *established*.

## What the probe counts, and what it does not

- **Counts:** every `requestAnimationFrame` in the host page — Tarmac's own React
  tree, xterm.js, the board transform, anything a dependency schedules — from the
  moment `devRafProbe.ts` runs. Outstanding = requested and not yet delivered or
  cancelled.
- **Does not count:** an HTML doc card's requests. Those live in the iframe realm
  behind `card_shim.js`, which is a different instrument for a different question
  (see `cull-qa.md` S37). That is the point of this one.
- **Does not measure CPU.** Do not mix a run of this sheet with a CPU cell: the
  wrapper is a pass-through and does not change *when* frames are serviced, but
  it is still one extra closure per request, and `cull-qa.md`'s bands were taken
  without it.
- **Reads the dev page, not the shipped one.** The probe exists only under
  `vite dev` (that is what makes it free in release), so the page under
  measurement also carries the HMR client, the react-refresh preamble and
  React's development build. None of those holds a frame at idle, so the dev
  page's schedulers are a **superset** of the release page's: a PASS in dev
  bounds the release app from above and does establish the regime, while a FAIL
  in dev has to be diagnosed — attributed to a specific scheduler — before it
  says anything about the shipped app.

**What a non-zero sample is expected to be.** With `cursorBlink: true`
(`src/cards/TerminalCard.tsx`), the WebGL renderer's blink manager arms a 600 ms
`setInterval` and requests **one** frame per tick
(`@xterm/addon-webgl/src/CursorBlinkStateManager.ts`). That request is
outstanding for at most one frame period, so at 20 Hz it should show up in
roughly 3% of samples — transient, not standing, and inside what the 95% bar
allows. A `zeroFraction` far below the bar is therefore not the cursor; it is a
loop that re-requests every frame, and R2's transition log is where to find it.

## Setup

```sh
make kill-daemon                       # socket-scoped; never `pkill tarmacd`
VITE_TARMAC_RAF_PROBE=1 make run
```

The flag is the dev opt-in — a plain `make run` installs nothing, and
`vite build` drops the probe from the bundle entirely (`DEV` is statically
false). Then, in the dev app:

- [ ] Right-click the empty board background → **Inspect Element** to open the
      Web Inspector (debug builds only), and switch to its Console.
- [ ] The console already carries
      `[tarmac raf] probe installed — run __tarmacRafSample() to measure`.
      **No banner means the flag did not reach the bundle** — a page that holds
      no request and a probe that never installed read identically, so do not
      proceed without it.

The API on `window`:

| | |
| --- | --- |
| `__tarmacRafOutstanding` | live count, read at the instant of the read |
| `__tarmacRafSample(ms = 10000, hz = 20)` | Promise of `{samples, zeros, zeroFraction, max, series, transitions}`, also printed as one console line |
| `__tarmacRafTransitions()` | the last 256 count changes, `{t, n}`, `t` from `performance.now()` |

The sampler is timer-driven and writes no DOM — a sampler that scheduled its own
frame would hold exactly the request it exists to detect, and one that painted a
live overlay would stop the board being idle.

## R1 — an idle board with a *focused* terminal holds no request

The regime cell. Board state: **one focused terminal, no HTML cards**, nothing
running in the shell.

Typing in the Web Inspector moves first responder off the page, which blurs the
terminal — so the sample has to be armed first and the click made after. Running
`__tarmacRafSample()` directly would measure the blurred cell and label it the
focused one, which is precisely the substitution 2609.0002 refused to make.

- [ ] Let the app settle for ~10 s after launch (the boot PTY spawn and first
      paint are not idle).
- [ ] In the console, arm the sample:
      `setTimeout(() => __tarmacRafSample(), 5000)`
- [ ] Immediately click into the terminal so it has focus (a blinking cursor is
      the tell), then **do not touch the window, the mouse or the trackpad until
      the result line prints** — a hover or a scroll is board work and will show
      up.
- [ ] The line arrives in the console ~15 s later. **Pass iff
      `zeroFraction ≥ 0.95`.** Record it, plus `max`.

A pass establishes the **isolated** regime and the ~6-point figure that goes with
it. A fail — a count that sits at 1 — establishes the opposite, and the gate's
recoverable value on an idle board is the *shared* row's ~3–5 points instead.
Either outcome is a result; record what was seen, not what was expected.

## R1b — the blurred terminal

2609.0002's *Not measured* list includes the blurred-terminal cell: a synthetic
click failed to remove xterm focus there, and by that doc's own rule a CPU band
could not stand in for the count. The Web Inspector removes focus for real, so
this cell costs one line here.

- [ ] With the Inspector focused (i.e. right after R1's line prints, without
      clicking back into the app), run `await __tarmacRafSample()` and keep hands
      off the trackpad.
- [ ] Record `zeroFraction` and `max`. There is no pass bar: this cell exists to
      be *known*. Expect it to be at least as quiet as R1 — a blurred terminal
      stops blinking — and note it if it is not.

## R2 — the count follows a real gesture

Proves the instrument responds to work, and that nothing in the board leaks a
standing request after a pan.

- [ ] Note the display's refresh rate (▸ About This Mac → Displays, or System
      Settings → Displays) — one frame is ~17 ms at 60 Hz, ~8 ms at 120 Hz.
- [ ] Run `const p = __tarmacRafSample(15000)`, then **pan the board** by
      dragging the empty background continuously for ~5 s, and release. Stay off
      the trackpad after the release until the sample resolves.
- [ ] `await p` and read the result, then `__tarmacRafTransitions()`.
- [ ] **Pass iff** all three hold:
      - `max ≥ 1` and `zeroFraction` is well below R1's — the count rose during
        the gesture;
      - the transition log **ends at `n: 0`** — the board is not holding a frame
        after the gesture;
      - the gap from the last `n: 1` entry to that final `n: 0` is **≤ one frame
        period** for the display — it fell back within one frame of the last
        request the gesture caused.

A tail that ends at `n: 1`, or a final 1 → 0 gap of hundreds of milliseconds, is
a real finding: something schedules a frame the board never services, and R1's
reading on that build is about that leak rather than about the idle regime.

## Recording the result

- [ ] Replace the **Status** heading above with the outcome, the date, the
      commit, and the printed lines from R1, R1b and R2.
- [ ] Update the offscreen-card note in `../../docs/architecture.md` with the R1
      reading, upgrading *consistent with isolated* to *established* — or
      refuting it. One sentence, with the number in it; that sentence is the
      deliverable of #105, and it may not be written before R1 has run.
