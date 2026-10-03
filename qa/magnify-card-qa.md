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

## S9 — Retained zoom applied at ready — **RETIRED** (spec 2609.0003, #99)

**Do not run this scenario. It is retired, not skipped.** Its manual repro could
never reach the branch it was written for, which is why it stood NOT VERIFIED
from the day it was written.

The branch is the shim's `pendingZoom` retention (`card_shim.js:257`, `:302`,
`:318`). Reaching it requires the host's zoom reply to land on a document that
has committed and installed its listener but has not yet reached
`DOMContentLoaded` — a race that is timing-dependent and cannot be staged by
hand. The settle-driven recipe this section used to prescribe could not reach it
at all under frozen-K.

- **Replaced by an automated test, not by another manual run:** `2609.0003 S8` in
  `desktop/src/card-shim.test.ts` drives exactly that order against the shipped
  shim bytes (`loadShim()` → `send({tarmac:"zoom", z:3})` → `domReady()`), with a
  negative control proving the value was *retained* rather than applied on
  arrival. It runs on every `make test`.
- **The branch is kept**, on cost and coverage rather than correctness: deleting
  three `include_str!`-embedded lines forces a Rust rebuild and re-opens the
  2607.0006 shim surface for no behavioral change. Since #99, the retained value
  is in fact *redundant* with the reply to the same document's own `ready`.
- **The user-visible question this section used to gesture at** — what a card
  looks like after `location.reload()` — is now its own scenario: **2609.0003
  S11** below, which is where the #99 bug was actually observable.

See `.blueprint/specs/2607.0006_magnify_zoom_mode_for_html_cards.md` S9's
`**Correction (#99):**` paragraph for the full reasoning.

## S10 — Magnified file reload preserves zoom

- [ ] Open a magnify document and zoom it to 2× or higher, then end the
      gesture. (A magnify card has no settle of its own — `HtmlCard`
      disconnects the zoom watcher — so this is just "stop gesturing".)
- [x] Rewrite the file on disk (e.g. add a comment, `touch` it, or edit the
      content).
- [ ] Card reloads within 100ms (check iframe src in devtools for a new `?v=<mtime>`).
      The document comes back magnified at the current board zoom (e.g. still
      2×), not reset to 1×.
- [x] **Added for 2609.0003 S13 (#99):** exactly one line beginning `zoom-mode`
      for the new load, and exactly one `z = 3` entry in the received-zoom panel.
      The `?v=` path resets the host's per-load state, so this must look exactly
      as it did before #99 — this item is the regression check that the fix did
      not disturb the ordinary reload.

Observation (2026-09-05, `7702f59`): **PASS for the #99 bullet.** Run on
`s11probe.html` — see **Run conditions** at the end of this sheet for the fixture
and every launch deviation — at board zoom **144%**, not 2×, which is why the
first bullet stays unchecked. Appending an HTML comment to the file while the
card was visible reloaded it: generation 4 under the fixture's `window.name`
counter, the received-zoom panel reset to a single new entry
`2026-09-05T12:56:56.316Z — {tarmac:"zoom", z:3} from window.parent`, and the
document came back magnified at the current board zoom — `ICB probe offsetWidth`
1207.0 px against `window.innerWidth` 3621.0 px (ratio 3.000), `prose line count`
15, box B 960.0 px, every number identical to the pre-edit reading
(`s13_v_reload.png`). The console strip gained **exactly one** new
`zoom-mode declared=magnify effective=magnify` line for the load; its tail reads
`gen=4 zoom=1 (unset, initial load) … icbProbeWidth=1738.0` → `zoom-mode
declared=magnify effective=magnify` → `received … z:3` → `gen=4 zoom=3 …
icbProbeWidth=579.0` → `gen=4 zoom=3 … icbProbeWidth=1207.0` (`s13_strip.png`).
The intermediate `579.0` is the iframe being briefly sized at the settled board
zoom while `magnify` is false — the `lastChangedMs` effect resets it — before
the mode is re-adopted and the box returns to `frame × K`. The third bullet
stays unchecked: no inspector was available in this build, so the iframe `src`
was never read and
the reload latency was never measured — the new load is evidenced instead by the
panel reset plus that new `zoom-mode` line, which only the `lastChangedMs` reset
effect can produce, and by the header's freshness chip flipping to `now`.

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

**The tell changed with #99 (spec 2609.0003 S14). Read this before running.**
The host now posts `{tarmac:"zoom", z: MAGNIFY_K}` in reply to **every** genuine
`ready`, so that a document which reloads itself comes back magnified instead of
at 1/K. A forged repeat is indistinguishable from a genuine one at the message
boundary, so it draws a reply too. **"The received-zoom panel gains no second
entry" is therefore no longer the tell and must not be failed on.** What the
once-per-load guard still protects — and what this scenario now asserts — is the
console line and the mode actually in force.

Frozen K had already changed this scenario's other tell: the host posts once per
document load rather than per settle, so "a new entry appears on the next settle"
signals nothing either.

- [x] Open `magnify-probe.html` as a card and let it load. The console strip
      shows exactly **one** line beginning `zoom-mode` — reading `zoom-mode
      declared=magnify effective=magnify` — and the probe's "received zoom
      messages" panel shows one entry. Count that prefix, not the strip: a
      `magnify-probe.html` load produces five console entries in total, only one
      of which is the host's (see S8's note on grepping the prefix, not prose).
- [ ] Borrow the card, open its console, select the card's iframe as the
      execution context (same caveat as S15 — the top-document context makes
      this a silent no-op), and post a forged second `ready`. `ready` travels
      shim→host, so target `window.parent`, same direction as the genuine one.
      **Forge `meta:"magnify"`, not `"reveal"`** — magnify is the branch that
      posts a zoom message, so it is the one whose leak would be visible:
      `window.parent.postMessage({tarmac:"ready", meta:"magnify"}, "*")`.
- [x] Console strip still shows **exactly one** `zoom-mode` prefixed line for
      this document load — the strip never disagrees with the mode actually in
      force. **This is the tell now.** With the once-per-load guard deleted, a
      second line appears here immediately.
- [x] The rendered zoom does not change and wrap points stay frozen when you
      zoom the board afterwards.
- [x] **Expected, NOT a failure:** the received-zoom panel **may** gain a second
      `{tarmac:"zoom"}` entry carrying the same `z = 3`. Re-applying the frozen
      constant is idempotent and cannot move a wrap point. Do not file it.
- [x] Repeat with `meta:"reveal"` forged. Same result: no second console line,
      no change in rendered zoom, wrap points still frozen. (The reply is still
      the magnify payload, because a repeat is decided by the mode in force, not
      by what the forgery claims.)

Observation (2026-09-05, `7702f59`): **PASS.** No devtools console exists in this
build, so both readies were forged from buttons added to `s11probe.html`; each
runs `window.parent.postMessage({tarmac:"ready", meta:…}, "*")` from the card
document while the card is borrowed — the same call, in the same execution
context, this scenario prescribes (**Run conditions** below). The second bullet
stays unchecked for that reason: the card was borrowed and the forgeries did come
from inside the document, but no execution context was selected, because no
inspector offered one. Before the
forgeries the strip held one `zoom-mode declared=magnify effective=magnify` line
and the panel one `z:3` entry. `meta:"magnify"` and then `meta:"reveal"` each
drew a reply, taking the panel to three entries — `…12:55:15.411Z`,
`…12:55:55.447Z`, `…12:56:05.758Z`, **all `z:3`**. The reveal forgery was
therefore answered with the *magnify* payload: the reply is decided by the mode
in force, not by what the forgery claims. The strip gained **no** second
`zoom-mode` line — the badge went 26 → 29 → 32 (26 and 29 derived from the
strip, 32 read off the badge), i.e. exactly three probe entries per forgery
(`[qa99] forging ready meta=…`, `[magnify-probe] received …`,
`[magnify-probe] gen=3 zoom=3 … icbProbeWidth=1207.0`) and nothing else
(`s14_strip.png`). The render did not move (`s14_forged_both.png`), and zooming
the board to 144% afterwards left `ICB probe offsetWidth` 1207.0 px, `prose line
count` 15 and box A's wrap points identical (`s14_after_zoom.png`).

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

- [x] Open `magnify-probe.html` as a card (meta present, magnify declared).
- [x] The probe's "received zoom messages" panel shows exactly **one**
      `{tarmac:"zoom"}` entry, whose `z` equals `MAGNIFY_K` (3, in
      `desktop/src/kit/cardZoom.ts`) — a constant, not the board zoom.
- [x] Its source reads `window.parent` (not "other source").
- [x] Zoom the board to 2–3 further levels, ending the gesture at each. The
      panel gains **no** further entries. One per settle is the settle-time
      shape returning — the thing that re-wrapped the text.
- [x] Rewrite the file on disk so the card reloads. The panel (reset with the
      document) shows one entry again: one per *load*, not one per card
      lifetime.
- [x] **Added for 2609.0003 S12 (#99):** count the console line by its
      `zoom-mode` prefix (S8's rule), not by the strip's total — a
      `magnify-probe.html` load logs five entries and only one is the host's.
      **Scope note:** "one per load" is now precisely "one per genuine `ready`",
      which is the same thing for every step in this checklist, since none of
      them forges a `ready` or reloads a document from inside itself. The two
      cases where the count can legitimately differ are 2609.0003 S14 (a forged
      repeat draws a reply) and `2609.0003` S11 (a reload crossing a zoom in
      flight can retain one *and* receive the reply — note that is the NEW S11 in
      the 2609.0003 section below, not the mid-gesture S11 above).

Observation (2026-09-05, `7702f59`): **PASS.** On first open of `s11probe.html`
at board zoom 100% the panel held exactly one entry —
`2026-09-05T12:47:27.768Z — {tarmac:"zoom", z:3} from window.parent` — whose `z`
is 3, the `MAGNIFY_K` constant, and whose source reads `window.parent`
(`s12_first_open.png`). Counting by the `zoom-mode` prefix across the whole
18-entry strip, scrolled top to bottom (`s12_strip_top.png`,
`s12_strip_bottom.png`), found exactly one line, `zoom-mode declared=magnify
effective=magnify`; the other 17 are `[magnify-probe] …` reports, most of them
fired by the resize that sizing the card produced — which is precisely why the
prefix, not the badge total, is the count. Zooming the board 100% → 207% → 144%
added **no** panel entry and no console line, and left the report unchanged:
`s11_pre.png` is the same generation 1 at 144%, still showing the single panel
entry `12:47:27.768Z … z:3` and `ICB probe offsetWidth` 1207.0 px, `prose line
count` 15, box B 960.0 px. The 207% step itself was not photographed. The
file-rewrite step is recorded under **S10** above (panel reset to one entry for
the new load).

---

# Spec 2609.0003 (#99) — self-reload scenarios

**These are spec `2609.0003`'s scenario ids, not 2607.0006's.** This sheet
already has an unrelated S11 (mid-gesture) above; every id below is written
`2609.0003 S<n>` for that reason. Same setup rules as the rest of the sheet
(`make run`, fresh dev daemon, kill any installed `tarmacd` first).

**Status: RUN 2026-09-05 against `7702f59` (PR #107) — all six PASS.** The fix
landed with its automated tiers green (`2609.0003` S1–S7 in
`desktop/src/kit/zoomMode.test.ts`, S8–S10 in `desktop/src/card-shim.test.ts`);
this is the manual half. **Read `## Run conditions` at the end of this sheet
before trusting any number below** — the reload was not issued from a devtools
console (there is none in this build), "above 1×" means 144%, and every
console-line count is a delta rather than a total.

Where the other ids live, so nothing looks missing:

| id | where it is run |
|---|---|
| 2609.0003 S11 | below — new |
| 2609.0003 S12 | the added bullet under **S18** above (first open, prefix counting) |
| 2609.0003 S13 | the added bullet under **S10** above (`?v=` reload unchanged) |
| 2609.0003 S14 | **S17** above, rewritten in place (forged repeat; the panel is no longer the tell) |
| 2609.0003 S15 | `cull-qa.md` **S36**, re-run with one added assertion |
| 2609.0003 S16 | below — new |

## 2609.0003 S11 — a self-reloading card comes back at board zoom, not 1/K

The bug #99 fixed, and the reason `magnify-card-qa.md` S9 above is retired: a
document that reloads *itself* changes neither `src` nor `lastChangedMs`, so
before the fix the host discarded its `ready` and sent it no root zoom at all —
leaving it laid out in a `K×` viewport inside a `frame × K` box, i.e. rendered at
a third of its size with broken scroll height.

**Premise: a VISIBLE, unculled card.** A culled card is `visibility:hidden`
(#106) and cannot be double-clicked to borrow, so the console recipe below is
unavailable there; the culled path is `cull-qa.md` S36 (2609.0003 S15) instead.

- [x] Open `magnify-probe.html` as a card and zoom the board above 1× (e.g. 2×).
      Let it settle.
- [x] **Record the probe's report block now** — `prose line count`, `ICB probe
      offsetWidth`, `window.innerWidth` — and the received-zoom panel's contents.
- [ ] Borrow the card (double-click), open its console, and **select the card's
      iframe as the execution context** (the top-document context makes the next
      step a silent no-op — same caveat as S15/S17).
- [x] Run `location.reload()`.
- [x] **Tell 1 — the wire.** The received-zoom panel (it resets with the
      document) shows **at least one** `{tarmac:"zoom"}` entry with `z = 3`.
      Before the fix it reads `(none received)`. **Zero is the only failure;
      two is a pass** — a reload crossing a zoom in flight can retain one *and*
      receive the reply to the new document's own `ready`, same `z`, same render.
- [x] **Tell 2 — the geometry, and the one number that discriminates.** `ICB
      probe offsetWidth` equals its pre-reload value. It is the layout viewport
      in the document's own units, so a root zoom that landed makes it the
      un-zoomed box width and a missing one makes it **3× that**.
- [x] **Tell 3.** `prose line count` matches its pre-reload value (a `3×` wider
      viewport re-wraps).
- [x] **Do NOT use `window.innerWidth` as the tell.** It tracks the iframe
      *element*, which the host sizes `frame × K` either way, so it is identical
      under the bug and under the fix. Record it as the control — it should
      **not** move.
- [ ] Optional cross-check: `wrap-probe.html`'s character-offset signature is
      unchanged across the reload.
- [x] **Expected, not a bug:** the console strip gains **no** second `zoom-mode`
      line. The fix deliberately keeps that line once per load; only the render
      was wrong, and only the render is fixed.

**Fallback if the iframe execution context is unavailable** (the dev inspector
does not always offer it): use a copy of `magnify-probe.html` that calls
`location.reload()` once — guarded by `window.name`, the `cull-qa.md` S36 idiom —
from inside its own received-zoom handler. Generation 1 receives the zoom and
reloads; generation 2 must receive one too. Same premise, no devtools needed.

Observation (2026-09-05, `7702f59`): **PASS**, run twice — generation 1 → 2 at
board zoom 100% and generation 2 → 3 at 144%. The 144% run is the one this
scenario asks for; the 100% run is supplementary. The console context is not
available in this build, so `location.reload()` was called from a button added
to `s11probe.html` and clicked in the borrowed card — the sheet's fallback in a
variant that keeps a same-card pre-reload capture (**Run conditions** below).
The third bullet stays unchecked for that reason: no execution context was
selected, because no inspector offered one.

*Generation 1 → 2, board zoom 100%* (`s12_first_open.png` → `s11_gen2_zoom100.png`).
Pre-reload: `ICB probe offsetWidth` 1207.0 px, `window.innerWidth` 3621.0 px
(ratio 3.000), `prose line count` 15, box B 960.0 px, panel one entry
`12:47:27.768Z … z:3`. Post: generation 2, every one of those numbers identical,
panel reset to exactly one entry `12:53:29.811Z … z:3`.

*Generation 2 → 3, board zoom 144%* (`s11_pre_144.png` → `s11_post_144.png`) —
note the pre-state here is itself a self-reloaded generation. Pre: ICB 1207.0,
innerWidth 3621.0, lines 15, box B 960.0, panel one entry `12:53:29.811Z … z:3`.
Post: generation 3, **ICB still 1207.0 px — not 3621.0, the 3× a missing root
zoom would give**; innerWidth unchanged at 3621.0 (the control, as prescribed);
lines still 15; box B still 960.0; panel reset to exactly one entry
`12:55:15.411Z … z:3`. One entry, not zero, is the wire tell; two would also
have passed.

The strip shows the mechanism directly (`s11_strip_gen2.png`,
`s11_strip_gen3.png`): after each `[qa99] self-reload from gen=N`, the new
generation's *first* report reads `icbProbeWidth=3621.0` — the un-zoomed, 3×
viewport that is the #99 bug's steady state — and the next two entries are
`received … {tarmac:"zoom", z:3}` and `icbProbeWidth=1207.0`. That is the reply
to the reloaded document's own `ready` arriving and landing. Neither reload
produced a second `zoom-mode` line. The optional `wrap-probe.html`
character-offset cross-check was **not run**.

## 2609.0003 S16 — a reveal card's self-reload stays reveal

The render-level counterpart of the in-force invariant (`2609.0003` S7): a repeat
`ready` is answered from the mode **already in force**, never from what that
`ready` claims. If it were answered from the claim, a forged or re-declared
`meta:"magnify"` would inject root zoom `K` into a reveal document and break its
layout outright.

**Fixture: the S8 recipe, not `wrap-probe-reveal.html`.** Use a copy of
`magnify-probe.html` with its meta flipped to `<meta name="tarmac-zoom"
content="reveal">` — exactly what S8 above prescribes. `wrap-probe-reveal.html`
is the wrong instrument here: it is a wrap-signature probe and has **no
received-zoom panel**, so the assertion below could not be read off it at all.

- [x] Open that copy with `tarmac open <file>` and zoom the board above 1×.
      Console strip reads `zoom-mode declared=reveal effective=reveal` — one
      line, and note it says `effective=reveal`, not `magnify`. The received-zoom
      panel reads `(none received)`.
- [ ] Borrow it, select the card's iframe as the execution context, run
      `location.reload()`.
- [x] The received-zoom panel is **still `(none received)`** — no
      `{tarmac:"zoom"}` entry arrives for the reloaded document. This is the
      assertion, and it is what a mutant deciding a repeat from the ready's own
      `meta` would break.
- [x] The document comes back laid out at real screen px and re-wraps as you
      zoom, exactly as a reveal card did before the reload — not frozen, not
      magnified, not at 1/K.
- [x] The console strip gains no second `zoom-mode` line.

Observation (2026-09-05, `7702f59`): **PASS.** Fixture `s16probe.html` — the
`magnify-probe.html` copy with the meta flipped to `content="reveal"`, per the
S8 recipe, plus the QA controls described under **Run conditions**. On open, the
console strip read exactly one `zoom-mode declared=reveal effective=reveal`
(badge `⌥ 2`: that line plus the probe's own first report —
`s16_declared_reveal.png`, which is cropped to the badge and that strip line) and
the panel read `(none received)` (`s16_pre_reveal.png`). At board zoom 144%:
root zoom `1 (unset, initial load)`, `ICB probe offsetWidth` 1728.0 px =
`window.innerWidth`
1728.0 px (ratio 1.000 — real screen px, 1200 × 1.44), `prose line count` 13
against 15 at 100%, box B 320.0 px (`s16_pre_reveal.png`). After the
document reloaded itself: generation 2, the panel **still reads
`(none received)`** — no `{tarmac:"zoom"}` arrived for the new load — root zoom
still unset, ICB 1728.0 = innerWidth 1728.0, lines 13, box B 320.0
(`s16_post_reveal.png`). Zooming back to 100% after the reload returned `prose
line count` to 15 and ICB to 1200.0: the reloaded document still re-wraps with
the board, so it is neither frozen nor magnified nor at 1/K
(`s16_rewrap_100.png`). The strip gained no second `zoom-mode` line and no
`received` entry — its tail is `[qa99] self-reload from gen=1` followed only by
two `gen=2 zoom=1 (unset, initial load)` reports (`s16_strip.png`). The second
bullet stays unchecked only on its execution-context clause: the card was
borrowed and the reload did come from inside the document, but from a button
rather than a console, because this build offers no inspector.

## Run conditions

For the 2026-09-05 run of `2609.0003` S11–S16 above, and of the S10 / S17 / S18
observations earlier in this sheet.

**Commit under test:** `7702f59` on `fix/99-magnify-self-reload` (PR #107 →
`m1/enrich-doc-card`). **Display:** a single 2560×1440 external monitor at 1×.

**Launch — not `make run`.** All Tarmac builds share the bundle id
`com.tarmac.desktop`, so the dev app was given its own: the debug binary
`desktop/src-tauri/target/debug/tarmac-app` was copied into a hand-written
`TarmacQA99.app` with `CFBundleIdentifier com.tarmac.qa99dev`,
`CFBundleExecutable TarmacQA99`, and an `LSEnvironment` carrying
`TARMAC_SOCKET`, `TARMAC_STATE`, `TARMAC_DAEMON` and `PATH` pointed into the
worktree; it was launched with `open`. A debug `cargo build` binary loads its
frontend from `devUrl`, so Vite ran alongside it on port 1420. The window was
sized to 2560×1366 through System Events. Cards were opened from the shell with
`TARMAC_SOCKET=… core/target/debug/tarmac open <file>`, not from a Tarmac PTY,
so the docs have no owning terminal. Unrelated but worth recording: `npm run
build` fails on this branch at a pre-existing TypeScript error in
`desktop/src/ipc/daemon.test.ts:35` (landed with #101, nothing to do with #99);
the dev-mode binary does not need it.

**"Above 1×" is 144%, not 2×.** Board zoom was driven by the bottom-left zoom
control, which steps by 1.2×, so the reachable levels are 100 / 120 / 144 / 173
/ 207 %. At 207% a card big enough to show the probe's report *and* its
received-zoom panel no longer fitted in the window, so the primary runs sit at
**144%**. Nothing is lost by that: for a magnify card all three tells — `ICB
probe offsetWidth`, `prose line count`, box B — are independent of board zoom
(that independence *is* frozen-K), so the discriminator between "root zoom
landed" (ICB = the card's frame width) and "it did not" (ICB = 3× that) reads
identically at every level.

**The iframe execution context was unavailable; the fallback was used in a
button-driven variant.** A right-click on a borrowed card produced no context
menu and no *Inspect Element*, so nothing could be typed into a console against
the card's iframe. **The cause was not established** — this was `cargo build`'s
`target/debug/tarmac-app`, where Tauri 2 gates the inspector on
`debug_assertions` as well as its `devtools` feature, so a missing feature flag
does not explain it; only the absence of the menu was observed. Scratch copies
of `desktop/qa/magnify-probe.html` were used instead, under
`../tarmac-worktrees/qa99-scratch/` (`s11probe.html`; `s16probe.html`, the
same file with the meta flipped to `reveal`). Each adds, and changes nothing
else:

- a `window.name`-backed **generation counter** (the `cull-qa.md` S36 idiom),
  shown in the report block and in every `[magnify-probe]` console line, so the
  two sides of a self-reload can never be confused;
- an `innerWidth / ICB probe` **ratio** line — 3.000 when root zoom `K` landed,
  1.000 when it did not — so each generation is decidable on its own, without
  the pre-reload capture;
- three buttons: `location.reload()`, and two that post
  `{tarmac:"ready", meta:"magnify"}` / `{…, meta:"reveal"}` at `window.parent`.

The buttons are clicked in the **borrowed** card, so their handlers run in the
card document: the same execution context the console recipe targets, issuing
the same calls. This variant was preferred to the sheet's zoom-handler fallback
because it preserves a **same-card pre-reload capture** — the zoom-handler
fixture reloads on receipt of the first zoom, before generation 1 can be read.
`desktop/qa/magnify-probe.html` itself was not modified.

**Console-line counts are deltas, not totals.** `HtmlCard`'s `entries` buffer is
never reset (cap 500), so it accumulates across self-reloads and `?v=` reloads
alike. Every "no second `zoom-mode` line" claim above is a pair of readings —
the badge count plus the strip's tail after scrolling it to the end: 18 → 22 →
26 across the two self-reloads, 29 → 32 across the two forged readies, 37 after
the `?v=` reload. **18, 22 and 32 were read off the badge in a capture; 26, 29
and 37 are derived from the strip**, because at 144% the card's header sits
above the window edge in those captures. Each event adds three to five
`[magnify-probe]` / `[qa99]` entries — five for the `?v=` reload, 32 → 37, whose
new load logs its own `zoom-mode` line and an extra intermediate report — and a
`zoom-mode` line only where S13 expects one.

**How the card was culled (S15).** By wheel-panning the board about 2.8
viewports to the right and back, not by switching boards: a card on an inactive
board is `display:none`, which is not the cull path #106 gates. Recorded again
in the `cull-qa.md` S36 re-run observation.

**Other deviations and noise.** The first press of the reload button at 144%,
issued immediately after the right-click that probed for an inspector, did
nothing (the badge count did not move); repeated at the same zoom without a
preceding right-click, it worked. Recorded as input noise, not a finding. The
screenshots named in the observations live in
`../tarmac-worktrees/qa99-scratch/`; each is cropped to the QA app's own window
and none shows any other Tarmac build.
