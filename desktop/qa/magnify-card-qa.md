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

- [ ] Open a document with `<meta name="tarmac-zoom" content="magnify">` and
      prose paragraphs or a diagram.
- [ ] Zoom the card below 1× (e.g. 0.5×, 0.3×), settle; then above 1× (e.g.
      1.5×, 2×, 3×), settle. At least one zoom below and one above.
- [ ] Text wrap points never change across zoom levels (same line breaks as
      seen at 1×, scaled but not reflowed).
- [ ] Glyphs are crisp at rest after each zoom settles (no persistent blur; brief
      softness mid-gesture is expected).
- [ ] Tested on both a 1× and a 2× display.
- [ ] Card console strip contains exactly one line per document load reading
      (verbatim, from `HtmlCard.tsx`): `zoom-mode declared=magnify
      capable=true effective=magnify`.

## S8 — Reveal-more fallback when magnify meta is absent

- [ ] Open `magnify-probe.html` (or a copy) with the `<meta name="tarmac-zoom"
      content="magnify">` line commented out or deleted, then `tarmac open <file>`.
- [ ] Zoom the card across several levels (at least one below 1×, one above),
      settling at each.
- [ ] Content re-wraps identically to a standard 2607.0004 card: line count and
      wrap points change when zoom changes; the ICB probe's `offsetWidth` and
      `innerWidth` both increase proportionally.
- [ ] Card console strip never logs any received `{tarmac:"zoom"}` message (no
      "received" entry when inspecting the strip).
- [ ] No line beginning `zoom-mode` appears in the console strip (that prefix
      is the stable anchor — do not grep for prose like "declared magnify").

## S9 — Retained zoom applied at ready (self-reload only, defensive branch)

**This branch is defensive; neither a first open nor a `?v=` reload can
reach it.** The host only posts `{tarmac:"zoom"}` while its effective mode is
magnify, and `effectiveZoomRef`/`readyHandledRef` reset in the same commit
that bumps `?v=` (keyed on `lastChangedMs`) — so `pendingZoom` stays null on
both a first open and a file-rewrite reload. The one reachable trigger is a
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
      not change, so the second genuine `ready` is discarded as a repeat and
      capability is never re-probed — do not report the silence as a
      failure.

**Standing note:** do not delete the `pendingZoom` retention branch on the
strength of a not-verified result. It guards a race the host cannot rule
out, and it costs three lines.

## S10 — Magnified file reload preserves zoom

- [ ] Open a magnify document and zoom it to 2× or higher; allow it to settle.
- [ ] Rewrite the file on disk (e.g. add a comment, `touch` it, or edit the
      content).
- [ ] Card reloads within 100ms (check iframe src in devtools for a new `?v=<mtime>`).
      The document comes back magnified at the current board zoom (e.g. still
      2×), not reset to 1×.

## S11 — Smooth mid-gesture, frozen wrap during gesture, re-layout at settle

- [ ] Open a magnify document at 1×. Perform a pan/zoom gesture (pinch or
      scroll+modifier).
- [ ] Mid-gesture (while holding): card content scales smoothly under the
      gesture transform (temporary scale applied on top of magnify). Text wrap
      points do NOT change mid-gesture (layout is frozen by the transform).
- [ ] On gesture end (release): card settles within ~150ms (RASTER_SCALE_SETTLE_MS).
      Content re-lays out exactly once at settle, and glyphs are crisp after
      settle.
- [ ] Repeat at different board zoom levels (0.5×, 1.5×, 2×). Gesture behavior
      is identical to reveal-more cards.

## S12 — Fallback on zoom-incapable WebKit (split by method)

This scenario has two halves—one method checkable on any machine (via a forged
probe), one needs genuinely incapable WebKit. Verify what you can; record which
half you tested and how.

### Host branch (forged probe, checkable anywhere)

- [ ] Edit `desktop/src-tauri/src/card_shim.js`: in `probeZoom()`, after
      reading `zoomed`, set `zoomed = base` to forge a no-op verdict.
      `probeZoom()` is called from `tryReady()`, which both the direct
      `DOMContentLoaded` path and the deferred `waitForLayout()`/
      `ResizeObserver` path reach — one edit covers both, no need to forge
      twice. Run `make app` to rebuild.
- [ ] Open a document with `<meta name="tarmac-zoom" content="magnify">` and
      zoom it.
- [ ] Card console strip reads (verbatim): `zoom-mode declared=magnify
      capable=false effective=reveal`.
- [ ] Card console strip never logs any received `{tarmac:"zoom"}` message (no
      zoom messages reach the card).
- [ ] Content behaves as reveal-more: re-wraps when zoomed, one resize per
      settle.
- [ ] Revert the shim change and rebuild.

### Render half (genuine incapable WebKit only)

On a machine where WebKit no-ops `zoom` or leaves the initial containing block
at W units:
- [ ] Open a magnify document without forging the probe. The shim's genuine
      verdict will be `capable=false`.
- [ ] Zoom the card. Content re-wraps (reveals more) exactly as 2607.0004
      reveal-more today.
- [ ] Content does NOT freeze at 1× inside a growing frame. Line count, the
      ICB probe's `offsetWidth`, and `innerWidth` all change proportionally
      with zoom.
- [ ] One resize per gesture, same as reveal-more.

**Note:** If you can only test the forged-probe half, record that; CI and field
testing on older macOS will cover the genuine-incapable render half.

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

## S17 — Forged second ready does not flip effective mode

- [ ] Open `magnify-probe.html` as a card on capable WebKit and let it settle
      normally. Console strip shows exactly one line: `zoom-mode
      declared=magnify capable=true effective=magnify`.
- [ ] Borrow the card, open its console, select the card's iframe as the
      execution context (same caveat as S15 — the top-document context makes
      this a silent no-op), and post a forged second `ready` claiming a
      different mode/capability — `ready` travels shim→host, so
      target `window.parent` (the host), same direction as the genuine one:
      `window.parent.postMessage({tarmac:"ready", meta:"reveal",
      probe:{base:400, zoomed:400}}, "*")`.
- [ ] Immediately after posting the forgery, rendered zoom is unchanged (a
      flipped internal mode wouldn't repaint anything by itself — this alone
      is not proof the mode held).
- [ ] **Zoom the board again** (a normal gesture) and let it settle. Check the
      probe's "received zoom messages" panel (reused from S18): a new
      `{tarmac:"zoom"}` entry is appended and wrap points stay frozen at the
      new size, exactly as before the forgery. A binary tell for the same
      failure: if the panel gains **no** new entry on this settle, the forged
      `ready` flipped the effective mode even though nothing looked different
      right after posting it.
- [ ] Console strip still shows **exactly one** capability line for this
      document load (the forged `ready` does not append a second line), and
      that line still reads `effective=magnify` — the strip never disagrees
      with the mode actually in force.

## S19 — Magnify capability survives a non-active board

**Why:** `App.tsx` renders every board at once and `Board.tsx` sets
`display:none` on inactive ones, so a card whose document loads on a hidden
board has no layout to measure at `DOMContentLoaded`; the shim defers
`ready` until the card first has width, then probes and posts once.

### Setup (a) — restored card, non-active at launch

- [ ] On a board other than the one that will be active on next launch, open
      a magnify document, zoom it, and let it settle.
- [ ] Fully quit the app and relaunch it (`make run`) so the card is
      restored while its board is not the active one.
- [ ] Switch to that board.
- [ ] Console strip's capability line reads (verbatim): `zoom-mode
      declared=magnify capable=true effective=magnify` — the engine's real
      capability, not `capable=false effective=reveal` from a zero-layout probe.
- [ ] Magnify engages: zooming the board freezes wrap points as in S6.
- [ ] Exactly one capability line appears for this document load, logged at
      the moment the card first had layout (when its board was shown), not
      at document load.

### Setup (b) — file rewritten while on another board

- [ ] With a magnify card's board not active, rewrite the card's file on
      disk (edit its content; keep `<meta name="tarmac-zoom"
      content="magnify">`).
- [ ] Switch to that card's board.
- [ ] Same checks as (a): console strip's capability line reads (verbatim)
      `zoom-mode declared=magnify capable=true effective=magnify`, magnify
      engages, and exactly one capability line appears, logged when the card
      first had layout rather than at document load.

## S18 — Positive wire check: one zoom message per settle, correct z and source

The positive counterpart to S8's negative — without it, a regression that
silently stops the host from posting zoom messages at all would leave every
other item in this checklist green.

- [ ] Open `magnify-probe.html` as a card (meta present, magnify declared) on
      zoom-capable WebKit.
- [ ] Zoom the board to a new level and let it settle; repeat at 2–3 more
      levels.
- [ ] After each settle, the probe's "received zoom messages" panel gains
      exactly **one** new `{tarmac:"zoom"}` entry (not zero, not more than
      one per settle).
- [ ] Each entry's `z` equals the board zoom level just settled to.
- [ ] Each entry's source reads `window.parent` (not "other source").
