# Culled HTML card scheduler gate — manual QA checklist (spec 2609.0002, issue #72)

The [Q]-tagged scenarios S29–S39 the unit suites cannot cover: the React/Tauri shell
has no unit tests by design (only pure `kit/` logic and Rust are tested), and CPU is
not measurable from Vitest at all. Run against `make run` with a fresh dev daemon
(`make kill-daemon` first), or against a release bundle launched with the worktree's
`.dev/` socket and state for the CPU cells.

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`), since a
persistent installed daemon hijacks the dev app. For this sheet it matters twice over:
the CPU cells identify the WebContent and GPU XPC services by set-difference against
what was running *before* launch, so a second Tarmac (an installed build, or another
agent's QA app) both hijacks the daemon and makes the process attribution wrong.

## Status: NOT VERIFIED — 0/11

Nothing on this sheet has been run. Every box below is unchecked and every
Observation line is empty by design: the implementation commit ships the probe and
this checklist, and a separate QA pass fills them in against a real app. Until then
the feature's evidence is the automated suites (S1–S28, S40, S41, S42) only.

**Companion artifact:** [`cull-probe.html`](cull-probe.html) — open it with
`tarmac open desktop/qa/cull-probe.html`. Its URL switches (`n`, `loops`, `across`,
`ms`) make one file serve every cell below. It reports through the console relay with
a `[cull]` prefix, one line per period, carrying each family's delivery count **and
max inter-delivery gap**, the real wall time `dt` the window covered, its card-side
outstanding-rAF count, and a boot id.

> ### The evidence is `gapRaf`/`gapInt`/`gapTo`, never the counts
>
> A paused card emits **no lines at all** — the reporter is a timer, so the gate
> pauses it too (a card cannot hold an un-gated timer; the shim wraps `setInterval`
> before the file's first byte, and an un-gated `MessageChannel` reporter would
> contaminate the CPU cells this same probe serves). So the first line after an
> un-cull spans the pre-pause remainder **plus** the whole cull **plus** the gap from
> resume to the next reporter tick.
>
> **A correct build therefore reports NON-ZERO counts on that line** — it includes the
> running periods on both sides of the cull. Scoring on counts would record a false
> FAIL. The decidable quantity is each family's largest interval between two
> consecutive deliveries:
>
> | | reading |
> |---|---|
> | **gate held (PASS)** | `gapRaf ≈ gapInt ≈ gapTo ≈ dt`, within ~2 report periods |
> | **a family leaked (FAIL)** | that family's gap stays **~1000 ms** (WebKit throttles an offscreen frame's timers to ~1 Hz) while `dt` runs to seconds |
>
> So `dt=8500 raf=15 gapRaf=8400 int=31 gapInt=8400 to=31 gapTo=8400` is a **pass**:
> 8.4 s with nothing delivered in any family. The same line with `gapTo=1000` is the
> failure, whatever its count says.
>
> There is deliberately **no card-side `gate=off` switch** — nothing a card does can
> bypass the shim; an un-gated baseline comes from a build with the gate reverted.

> **Read all three gaps, every time.** An **un-gated** culled card *already* shows a
> large `gapRaf` — WebKit services a non-visible frame only about once every 10 s —
> while its timers keep running at ~1 Hz. So `gapInt` and `gapTo` are the gate's only
> rate-level evidence. A cell scored on `gapRaf` alone would be recorded VERIFIED
> against a build in which the `cull` message never arrives at all.

---

## S29 — Culled cards deliver nothing (criterion 1)

- [ ] Open one probe card (`?n=1`). Note its steady visible gaps (tens of ms).
- [ ] Pan until it culls (more than one viewport out), hold it culled for ~10 s,
      then pan back. On the **first line after un-cull**, `gapRaf`, `gapInt` **and**
      `gapTo` are each within ~2 report periods of `dt` — all three, not just `gapRaf`.
      Ignore the counts on that line; they are expected to be non-zero.
- [ ] Repeat with six probe cards (`?n=6`) on a 3×2 grid; every card shows the same
      three-gap-≈-`dt` reading.
- [ ] **The across-the-pause one-shot — mind the ordering, it is the whole cell.**
      The deadline is armed once at load and is fixed, so it discriminates nothing
      unless the cull actually *contains* it. **Cull the card within ~10 s of opening
      it, before any `ACROSS-FIRED` line appears, and hold it culled past the 12 s
      mark** — or open it as `?across=<ms>` with a deadline you know your cull will
      span. Every report line carries `across=pending|fired`; if it already reads
      `fired` before you culled, the cell is void — reload and retry.
- [ ] With that ordering satisfied, read the
      `[cull] ACROSS-FIRED at=… armedAt=… deadline=… elapsed=…` line: **`elapsed`
      must be visibly larger than `deadline`**, by roughly the part of the cull it
      waited through — that is a held-and-flushed timeout. An `elapsed` ≈ `deadline`
      means it fired on time, i.e. *while culled*, and is the failure. (Do not read
      the report counter for this: it is frozen during a cull, so both outcomes
      printed the same number.) This is the
      `setTimeout`-outstanding-across-the-pause case, which no measurement before
      this feature exercised.

Observation:

## S30 — Marginal CPU ≤ 1 point at every phase (criterion 3)

Sample **two consecutive 10 s windows, the first opening AT the pause** — not after
a settle. Baseline is the **same board with the probes' loops disabled**
(`?loops=none`), not an empty board: it holds card count, DOM, iframes and layout
fixed and varies only the thing under test.

**The probe must not rely on WebKit's 10 s service tick**, which is undocumented,
unversioned, and re-anchors its phase on any delivered frame. A cell that settles for
≥12 s before sampling scores a *hold*-gate as passing — exactly the error the
out-of-repo harness made before it added two-window sampling.

- [ ] N=6, `loops=all`, gated: window 1 marginal WebContent CPU ≤ 1 point.
- [ ] N=6, `loops=all`, gated: window 2 marginal WebContent CPU ≤ 1 point.
- [ ] Record the un-gated baseline **in the same session, on the same machine** —
      which means a second run against a build with the gate reverted:
      `git checkout 046f3bb -- desktop/src-tauri/src/card_shim.js`, rebuild, run the
      cell, then `git checkout HEAD -- desktop/src-tauri/src/card_shim.js` to restore.
      (Reverting only the shim is deliberate — checking out the whole parent commit
      would take the probe with it.) Expect
      roughly **+6 points**, which is #72 reproduced. There is no URL switch for
      this: nothing a card can do bypasses the shim. Without this cell the delta is
      being compared against a number from another machine.

Observation:

## S31 — Resume is prompt (criterion 4)

- [ ] With a culled, paused card, pan back. **The first full one-second bucket that
      begins after the un-cull** already reads within the card's pre-cull band.

Observation:

## S32 — Nothing inside the margin changes (criterion 5)

Tolerance decided at the spec gate: **overlapping rate bands plus ≤ 1 point of
marginal WebContent CPU**. Take both halves in one session, on one machine.

- [ ] A card that stays visible (or within the one-viewport margin) shows rate bands
      overlapping the same card measured with the gate reverted.
- [ ] Its marginal WebContent CPU differs by ≤ 1 point from the same.

Observation:

## S33 — The round trip is invisible to the document (criterion 6)

**Use a card carrying an explicit `<meta name="tarmac-zoom" content="magnify">`** —
`magnify-probe.html`, or `cull-probe.html`, which carries one. Without the meta the
console line is never emitted at all (the host logs it only when `meta !== null`), so
"exactly one line" would be unfalsifiable.

- [ ] Note boot id, `scrollY`, root zoom, the ICB probe's `offsetWidth` and the
      ~300-character wrap signature (`wrap-probe.html` decides wrap by character
      offset, not by eye).
- [ ] Cull the card, then un-cull it.
- [ ] All five readings are **identical**. In particular the **boot id is unchanged**
      — a cull round trip must never reload the document (#72's third acceptance
      bullet, and the #99 failure path).
- [ ] The console strip still shows **exactly one**
      `zoom-mode declared=… effective=…` line — no second `ready` was honored.
      Cross-check `magnify-card-qa.md` S6 and S17.

Observation:

## S34 — P1: a card born culled never starts (criterion 7)

Worded as steady state on purpose: the card's script runs from load until the
`ready` → cull round trip completes, and the pause cancels what it issued. "Zero
callbacks ever" would fail a correct build — spec S34 asks for *at most its first
one-second bucket* to be non-zero.

- [ ] Open a probe card onto a region of the board that is already culled. It emits
      its `[cull] boot=…` line, then falls silent.
- [ ] Leave it culled ~10 s, then pan to it. On its **first line**, `gapRaf`,
      `gapInt` **and** `gapTo` are each within ~2 report periods of `dt`. **Its
      counts are non-zero by design** — that line carries the load burst before the
      `ready` → cull round trip landed, plus the post-resume gap — so score the gaps,
      never the counts.
- [ ] Failure signals: a **second** reporter line covering the cull (it should have
      been silent throughout), or any gap sitting near **~1000 ms** while `dt` runs
      to seconds.

Observation:

## S35 — P2: a `?v=` reload while culled comes back paused (criterion 7)

- [ ] With a paused, culled probe card, rewrite its file so `lastChangedMs` changes
      and the iframe reloads via `?v=`. A new `[cull] boot=…` line appears (new boot
      id), then silence — no per-period lines.
- [ ] Leave it ~10 s, then pan to it. On the first line under the **new** boot id all
      three gaps are within ~2 report periods of `dt`: the reloaded document came back
      paused, without any pan.

Observation:

## S36 — P3: the #99-shaped self-reload comes back paused (criterion 7)

**Never run before.** The design infers this from the guard analysis; this is its
first verification, and it is the scenario that requires the cull post to sit
**before** the `readyHandledRef` guard rather than after it. It must hold under
either resolution of #99.

- [ ] With a paused, culled card, borrow it (double-click), open its console and
      **select the card's iframe as the execution context** — the top-document
      context makes this a silent no-op.
- [ ] Run `location.reload()`. `src` and `lastChangedMs` are both unchanged, so
      `readyHandledRef` stays set. A new `[cull] boot=…` line appears, then silence.
- [ ] Un-borrow, leave it culled ~10 s, then pan to it. On the first line under the
      **new** boot id all three gaps are within ~2 report periods of `dt` — the
      self-reloaded document came back paused.

Observation:

## S37 — The probe is committed and instrumented (criterion 9)

- [ ] `desktop/qa/cull-probe.html` is in the repo, installs its rAF/cAF
      outstanding-count wrapper as the **first statement of its own script**, and
      reports `outstanding=` in every line.
- [ ] Its `n` / `loops` / `across` / `ms` URL switches all work, so one
      file serves every cell above.
- [ ] The in-app numbers from this sheet are recorded in
      `../../docs/designs/2609.0002_offscreen_html_card_throttle.md` and summarised
      in `../../docs/architecture.md`.

> The **host page's** outstanding-rAF count is a different instrument and is **not**
> part of this scenario — it needs a wrapper in the host document before the app's
> own code runs. It is [#105](https://github.com/pingeplin/tarmac/issues/105).
> Nothing on this sheet turns "Tarmac is consistent with the isolated regime" into
> "established", and no observation below should claim it does.

Observation:

## S38 — Cross-family flush order (pinned semantic 2)

The unit suite deliberately does not promise this: it is an engine property (a 0 ms
timeout runs before the next animation frame). Record it as observed.

- [ ] With both a timeout and rAF callbacks held across a pause, the delivery log on
      resume shows the **timeout callbacks before the re-issued frame callbacks**.

Observation:

## S39 — Non-active boards, and the documented gap

- [ ] Put probe cards on a second board and switch away from it (App keeps every
      board mounted and hides the inactive ones with `display:none`).
- [ ] Switch back after ~10 s: on each card the cull predicate reaches, the first
      line shows all three gaps within ~2 report periods of `dt` — they were paused.
- [ ] **Record explicitly that the card straddling that board's saved viewport
      centre is NOT paused.** A `display:none` board delivers a `0×0` ResizeObserver
      entry, `visibleWorldRect` degenerates to a zero-area rect at `(cx, cy)`, and
      `rectsIntersect`'s strict `<` (`../src/kit/placement.ts:33`) leaves "the frame
      strictly contains `(cx, cy)`" as the surviving predicate. That is **already
      true today**, is **not** fixed by this change, and closing it would touch a
      predicate shared with terminal and markdown cards — it is
      [#104](https://github.com/pingeplin/tarmac/issues/104), deliberately out of
      scope here. Record the observation under #104.

Observation:
