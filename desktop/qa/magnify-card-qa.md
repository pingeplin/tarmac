# Magnify zoom mode manual QA checklist (spec 2607.0006)

Companion to `magnify-probe.html` (S5). These are the [QA]-tagged scenarios
the unit suites cannot cover (DOM/webview zoom behavior; see repo testing
convention). Run against `make run` with a fresh dev daemon (`make kill-daemon`
first).

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`),
since a persistent installed daemon hijacks the dev app.

Setup: in a Tarmac terminal, open an HTML file with `<meta name="tarmac-zoom"
content="magnify">` by running `tarmac open <file>`. For Milestone 0, use
`magnify-probe.html` (built-in root-zoom control, auto-reporting line count,
layout viewport widths, box rects). For other scenarios, any magnify document
works; multi-line prose or a diagram is ideal for observing wrap points.

## S5 — Milestone 0 geometry gate

The design rests on this: root `zoom: z` inside an iframe of W real-px yields
a layout viewport of W/z CSS px (not W units with overflow). Verify before
committing any other change.

- [ ] Open `magnify-probe.html` as a card, double-click to borrow, use its
      built-in zoom control to set root zoom to 1, and record the reported
      values: line count, the ICB probe's `offsetWidth`, `window.innerWidth`,
      fixed-px box width, `width:100%` box width — plus, as evidence only,
      `compatMode`, root `clientWidth`, and `body clientWidth`.
- [ ] In the board, zoom from 1× to 2×, use the probe's control to set root
      zoom to 2, and record the same values again.
- [ ] **Pass iff all hold**: line count identical (zero change), the ICB
      probe's `offsetWidth` unchanged within 2 px (the expected pattern:
      layout viewport constant), `innerWidth` doubled within 2 px (iframe
      element grew, zoom did not), both box rects doubled within 2 px, no
      content overflow in card frame. The ICB probe's `offsetWidth` is the
      criterion — not `clientWidth` — because every `tarmac-card://`
      document is quirks mode, where root `clientWidth` measures the
      `<html>` element's own box, not the viewport; `compatMode` and the two
      `clientWidth` readings are recorded as evidence that this is so
      (expect `BackCompat`, and expect the two `clientWidth` values to
      disagree with each other about which one halved) — they are never
      themselves pass/fail criteria. If the ICB probe doubles alongside
      `innerWidth`, or the line count changes, the assumption is false —
      stop and report immediately.

## S6 — Magnify wraps freeze, glyphs crisp across zooms

Magnify is now the DEFAULT (`declaredZoomMode`), and its root zoom is frozen at
`MAGNIFY_K` rather than tracked per settle. There is no settle relayout left to
wait for, so the old "settle at each level" step is gone and the wrap-point
check is exact again rather than the ICB-only claim S6 was weakened to.

- [ ] Open a document with prose paragraphs or a diagram and NO `tarmac-zoom`
      meta — the default is what most cards will exercise.
- [ ] Sweep the card continuously from 0.25× to 3×, not level by level.
- [ ] Text wrap points never change anywhere in the sweep — same line breaks at
      every zoom, scaled but never reflowed. `desktop/qa/wrap-probe.html` decides
      this by character offset rather than by eye; a line COUNT holding while a
      break moves is the failure this catches.
- [ ] Glyphs are crisp at rest AND mid-gesture. Frozen K makes `scale(zoom/K)` a
      permanent down-scale, so the transient blur the settle path existed to
      resolve should be absent — mid-gesture softness is now a regression, not
      expected behaviour.
- [ ] Tested on both a 1× and a 2× display.
- [ ] Card console strip logs the `zoom-mode` line only when the document
      declares a mode. A default (meta-less) document logs nothing; that is the
      quiet common case, not a missing line.

## S8 — Reveal-more when the document deliberately opts out

Absent meta no longer means reveal — it means magnify. Reveal is now reached
only by declaring it, which is the point: opting out of a stable layout is a
choice with a reason behind it (honest viewport dimensions for a self-contained
D3/Canvas dashboard), not something a document falls into by saying nothing.

- [ ] Open a copy of the probe whose meta reads `<meta name="tarmac-zoom"
      content="reveal">`, then `tarmac open <file>`.
- [ ] A malformed value (`revealing`, `magnifying`, empty) must NOT reach this
      mode — it takes the magnify default. Check one.
- [ ] Zoom the card across several levels (at least one below 1×, one above),
      settling at each.
- [ ] Content re-wraps identically to a standard 2607.0004 card: line count and
      wrap points change when zoom changes; the ICB probe's `offsetWidth` and
      `innerWidth` both increase proportionally.
- [ ] Card console strip never logs any received `{tarmac:"zoom"}` message (no
      "received" entry when inspecting the strip).
- [ ] Exactly one line beginning `zoom-mode` appears, reading `zoom-mode
      declared=reveal effective=reveal` — the line is keyed on the meta being
      *present*, so declaring reveal logs it. Only a meta-less (default-magnify)
      document is silent, per S6. That prefix is the stable anchor — do not grep
      for prose like "declared magnify".

## S9 — Retained zoom applied at ready (self-reload only, defensive branch)

**This branch is defensive; neither a first open nor a `?v=` reload can
reach it.** The host only posts `{tarmac:"zoom"}` while its effective mode is
magnify, and `readyHandledRef`/`magnify` reset in the same commit that bumps
`?v=` (keyed on `lastChangedMs`) — so `pendingZoom` stays null on both a first
open and a file-rewrite reload. The one reachable trigger is a
document that reloads **itself** (card JS calling `location.reload()`, or
webview recovery): `src` and `lastChangedMs` never change, the host stays in
magnify, and a settle during that load window retains.

- [ ] Build a **copy of `magnify-probe.html`** that adds a multi-second
      synchronous busy-loop as the first statement of its `<script>`, ahead
      of anything that would let `DOMContentLoaded` fire (e.g.
      `const start = Date.now(); while (Date.now() - start < 3000) {}`). This
      delays readiness on every load of the file, including the self-reload
      below, and the busy-loop file is needed so the line-count /
      ICB-probe-width comparison further down has numbers to compare.
- [ ] `tarmac open` the file, zoom the board to > 1× (e.g. 2×), and let it
      settle. Confirm the console strip logged `effective=magnify` for this
      load.
- [ ] Borrow the card, open its console, and select the card's **iframe** as
      the execution context (same caveat as S15/S17 — the top-document
      context makes this a silent no-op).
- [ ] In the console, run `location.reload()`. This reloads the same `src` —
      `?v=` and `lastChangedMs` do not change.
- [ ] Immediately, during the busy-loop load window (before the reloaded
      document's `ready` fires), zoom the board again (e.g. to 3×) and let it
      settle.
- [ ] **Required instrumentation:** add a temporary line inside
      `card_shim.js`'s `postReady()`, logging `pendingZoom` right before the
      `if (pendingZoom !== null) applyZoom(pendingZoom);` check, rebuild
      (`make app`), and confirm the logged value is **non-null**. This is the
      only way to know the repro reached the retention branch rather than
      some other path; revert the instrumentation after the run.
- [ ] If `pendingZoom` was non-null at ready: once settled, the reported line
      count and ICB probe width match the same document opened fresh and
      zoomed to the same level *after* it finished loading.
- [ ] **If you cannot demonstrate `pendingZoom` was non-null at ready — record
      S9 as NOT VERIFIED, not passed.** A checked box here must mean the
      retention branch was actually exercised, not that the card ended up at
      the right zoom by some other path.
- [ ] **Expected, not a bug:** the reloaded document keeps its old mode and
      the console strip gains no second `zoom-mode …` line. The host's
      per-load reset keys on `lastChangedMs`, which `location.reload()` does
      not change, so the second genuine `ready` is discarded as a repeat — do
      not report the silence as a failure.

**Standing note:** do not delete the `pendingZoom` retention branch on the
strength of a not-verified result. It guards a race the host cannot rule
out, and it costs three lines.

> **Read this before running S9 — the repro above cannot reach the branch any
> more, and the reason is a suspected bug, not a spent scenario.** Under
> frozen-K the host posts `{tarmac:"zoom"}` from exactly one place
> (`HtmlCard.tsx:130`), inside the `ready` handler, and the shim sets its own
> `ready` flag *before* it posts `ready` — so nothing can deliver a zoom while
> the shim is still unready, and `pendingZoom` is never written. Worse, on the
> self-reload this scenario asks for, `readyHandledRef` is still `true`
> (`lastChangedMs` did not change), so the host ignores the reloaded document's
> genuine `ready` and posts **no** root zoom at all — while `magnify` stays on
> and the outer box stays `frame×K`, which renders the card at 1/K size. Found
> by code reading during #94/#95, not by a run; filed as **#99**. **Record S9 as NOT VERIFIED and
> report what the card actually looks like after `location.reload()`** rather
> than working around it here.

## S10 — Magnified file reload preserves zoom

- [ ] Open a magnify document and zoom it to 2× or higher, then end the
      gesture. (A magnify card has no settle of its own — `HtmlCard`
      disconnects the zoom watcher — so this is just "stop gesturing".)
- [ ] Rewrite the file on disk (e.g. add a comment, `touch` it, or edit the
      content).
- [ ] Card reloads within 100ms (check iframe src in devtools for a new `?v=<mtime>`).
      The document comes back magnified at the current board zoom (e.g. still
      2×), not reset to 1×.

## S11 — Smooth mid-gesture, wrap frozen through the gesture *and* after it

Frozen K removed the settle relayout this scenario was written around. The
document lays out once at `ready` and never again; `scale(zoom/K)` carries the
gesture and everything after it alike, so there is no moment of reflow and no
"after settle" state that differs from mid-gesture. The old checklist asked for
a relayout that can no longer happen.

- [ ] Open a magnify document at 1×. Perform a pan/zoom gesture (pinch or
      scroll+modifier).
- [ ] Mid-gesture (while holding): content scales smoothly and text wrap points
      do NOT change.
- [ ] On release: the wrap points are the *same* ones, and nothing re-lays out —
      no visible reflow and no line-count change at the moment of release. A
      reflow here is the regression frozen K exists to prevent.
- [ ] Glyphs are crisp mid-gesture as well as at rest. `scale(zoom/K)` is a
      down-scale at every board zoom ≤ K, so the transient blur a reveal-more
      card shows until its settle should be absent throughout.
- [ ] Repeat at 0.5×, 1.5×, 2×. Behaviour is identical at every level, because
      nothing about a magnify card's layout depends on the level — unlike a
      reveal-more card, which resizes once per `RASTER_SCALE_SETTLE_MS` settle.

<!-- S12 ("Fallback on zoom-incapable WebKit") removed in #94: the macOS 26
     floor (packaging/Casks/tarmac.rb, `depends_on macos: :tahoe`) leaves no
     zoom-incapable target, so the capability probe it tested no longer exists.
     Numbers are not reassigned — they are spec 2607.0006's scenario IDs, which
     tests and the spec both cite. -->

## S15 — Nested/forged zoom messages rejected (event.source guard)

- [ ] Open a magnify document. Borrow it (double-click), then open its console
      (press F12 or Inspector) and **select the card's iframe as the
      console's execution context** (DevTools defaults to the top document,
      where `window` is the host — both repros below silently no-op there).
- [ ] In the console, run: `window.postMessage({tarmac:"zoom", z: 40}, "*")` —
      targeting the card's **own window**, not `window.parent`. See the note
      below before "simplifying" this.
- [ ] Card rendered zoom is unaffected (stays at the current board zoom, does
      not jump to 40×). The shim's `event.source === window.parent` guard
      rejected the message, because here `event.source === window !==
      window.parent`.
- [ ] Alternative repro: add a nested `<iframe>` inside the card content and
      have it run `window.parent.postMessage({tarmac:"zoom", z: 40}, "*")`
      (its `parent` is the *card* document, not the host). Same result —
      ignored, because `event.source` (the nested iframe's window) is not
      `window.parent` (the host) as seen from the card document.

**Do not run `window.parent.postMessage(...)` from the card document itself
— it does not test this.** From inside a card document, `window.parent` IS
the host: that message travels *up* to `HtmlCard`'s relay (S16's territory),
and the shim's own `message` listener — which lives in the card document and
only ever receives messages addressed to the card's window — never sees it
at all. That check would report a false pass even with the
`event.source === window.parent` guard deleted outright, because nothing was
ever delivered to the guard to reject.

## S17 — Forged second ready does not flip the mode in force

Frozen K changed this scenario's tell. The host posts zoom **once per document
load**, in reply to `ready` — so "a new entry appears on the next settle" is no
longer a signal of anything. What the guard (`readyHandledRef`) protects is
that a second `ready` produces neither a second zoom message nor a second
console line.

- [ ] Open `magnify-probe.html` as a card and let it load. Console strip shows
      exactly one line: `zoom-mode declared=magnify effective=magnify`, and the
      probe's "received zoom messages" panel shows exactly one entry.
- [ ] Borrow the card, open its console, select the card's iframe as the
      execution context (same caveat as S15 — the top-document context makes
      this a silent no-op), and post a forged second `ready`. `ready` travels
      shim→host, so target `window.parent`, same direction as the genuine one.
      **Forge `meta:"magnify"`, not `"reveal"`** — magnify is the branch that
      posts a zoom message, so it is the one whose leak is visible:
      `window.parent.postMessage({tarmac:"ready", meta:"magnify"}, "*")`.
- [ ] The probe's received-messages panel gains **no** second `{tarmac:"zoom"}`
      entry. This is the binary tell: with `readyHandledRef` deleted, the
      forgery would post one immediately.
- [ ] Console strip still shows **exactly one** `zoom-mode` line for this
      document load — the strip never disagrees with the mode actually in force.
- [ ] Repeat with `meta:"reveal"` forged. Same result: no second console line,
      no change in rendered zoom, wrap points still frozen when you zoom the
      board afterwards.

## S19 — Magnify engages on a card whose board was not active at load

**Why:** `App.tsx` renders every board at once and `Board.tsx` sets
`display:none` on inactive ones, so a card can finish loading with no layout at
all. Before #94 the shim deferred `ready` until the card first had width, so it
could measure a capability probe; there is no probe now and `postReady` fires at
`DOMContentLoaded` regardless of visibility. The mechanism changed, the
user-visible risk did not — this checks the outcome, not the old path.

### Setup (a) — restored card, non-active at launch

- [ ] On a board other than the one that will be active on next launch, open
      a magnify document, zoom it, and end the gesture.
- [ ] Fully quit the app and relaunch it (`make run`) so the card is
      restored while its board is not the active one.
- [ ] Switch to that board.
- [ ] Console strip's line reads (verbatim): `zoom-mode declared=magnify
      effective=magnify`, and exactly one such line appears for this load.
- [ ] Magnify engages: zooming the board freezes wrap points as in S6, and the
      card is not rendered at 1/K size (the visible tell that root zoom never
      landed).

### Setup (b) — file rewritten while on another board

- [ ] With a magnify card's board not active, rewrite the card's file on
      disk (edit its content; keep `<meta name="tarmac-zoom"
      content="magnify">`).
- [ ] Switch to that card's board.
- [ ] Same checks as (a).

## S18 — Positive wire check: exactly one zoom message per document load, z = K

The positive counterpart to S8's negative — without it, a regression that
silently stops the host from posting zoom messages at all would leave every
other item in this checklist green.

Frozen K changed the count this asserts. The host posts once, in reply to
`ready`, and never again; "one per settle" was the settle-time shape.

- [ ] Open `magnify-probe.html` as a card (meta present, magnify declared).
- [ ] The probe's "received zoom messages" panel shows exactly **one**
      `{tarmac:"zoom"}` entry, whose `z` equals `MAGNIFY_K` (3, in
      `desktop/src/kit/cardZoom.ts`) — a constant, not the board zoom.
- [ ] Its source reads `window.parent` (not "other source").
- [ ] Zoom the board to 2–3 further levels, ending the gesture at each. The
      panel gains **no** further entries. One per settle is the settle-time
      shape returning — the thing that re-wrapped the text.
- [ ] Rewrite the file on disk so the card reloads. The panel (reset with the
      document) shows one entry again: one per *load*, not one per card
      lifetime.
