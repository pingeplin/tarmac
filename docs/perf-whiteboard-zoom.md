# Whiteboard zoom/pan performance — diagnosis & fix plan

Branch: `perf/whiteboard-profiling`. Symptom reported: panning ("normal
movement") and the zoom animation get janky once the board is zoomed **down to
~50%**, and worse below that. Initial guess was a rendering/compositing
bottleneck.

This doc records what the diagnosis actually found, ranked, with file:line and
a per-fix plan. It is the durable form of a multi-agent audit (6 parallel
tracers over the pan/zoom hot paths, every candidate adversarially verified
against the source — 33 findings, 31 confirmed, 2 refuted). The full verified
audit is the table in the appendix; the body is the deduped, actionable view.

## Verdict

The instinct was **half right**. The dominant cost is **CPU work on the main
thread**, not GPU compositing — and the reason 50% is special is a **hard-coded
threshold**, not anything about pixels.

There are three distinct causes, and together they explain why *both* panning
and the zoom animation degrade at 50%:

1. **The background dot grid** (primary; the actual 50% cliff) — CPU.
2. **No viewport culling** (secondary; the part the "rendering" hunch got right)
   — GPU compositing, but monotonic, not a 50% knee.
3. **Per-frame tax on every scroll event** (why *all* movement feels heavy,
   independent of zoom).

---

## 1. The dot grid — the 50% cliff

`Viewport.semanticZoomThreshold = 0.5` (`BoardModel.swift:55`), and
`isSemanticZoom` is `zoom < 0.5` (`:65`). The moment zoom drops **below** 0.5,
`BoardView.draw(_:)` switches the grid's world spacing **24px → 11px**
(`BoardView.swift:705`). Dot count scales with area, so this is a **~4.8×
(= (24/11)²) jump in a single frame** — a discontinuous knee exactly at the
zoom the user feels — and it keeps worsening as you zoom further out until the
grid blanks.

Per-frame dot count for a ~1920×1080 board:

| Zoom | World spacing | View spacing | Dots / frame |
|------|--------------|--------------|--------------|
| 0.50 (just above) | 24px | 12.0px | ~14,400 |
| 0.49 (just below) | 11px | 5.4px | **~71,000** |
| ~0.28 (worst) | 11px | 3.1px | **~232,000** |
| <0.273 | 11px | <3px → grid off | 0 (sudden relief) |

The per-dot work, in a tight nested `while` loop, **every pan and every zoom
frame**, on the main thread (`BoardView.swift:720-734`):

```swift
let v = worldToView(...)              // fn call into TarmacKit, per dot
let dot = NSRect(...)
if dirtyRect.intersects(dot) {        // always true on full-bounds redraw → culls nothing
    NSBezierPath(ovalIn: dot).fill()  // a fresh heap allocation per dot
}
```

Every scroll sets `needsDisplay = true` on the whole view, so `draw(_:)` runs
with `dirtyRect == bounds` — the entire lattice is re-projected and re-filled,
~60×/sec, with no caching, no tiling, no GPU layer. The `intersects` test culls
nothing (it can only cull under partial-rect invalidation, which never happens)
and just adds a branch per dot. During the zoom animation the **crossing frame**
is the worst single frame: the density flip forces a full grid redraw
concurrently with `reprojectAll` + content-scale work.

**Fix (high confidence):** take `draw(_:)` off the pan/zoom hot path. Move the
grid into its own backing layer whose contents are scale/translate-invariant — a
`CGPattern`-backed (pattern color) layer or `CAReplicatorLayer` — so **pan = a
layer position change and zoom = a layer transform, both GPU, zero `draw(_:)`
calls**. Cheap interim if we stay CPU-side: batch all dots into a **single**
`CGPath`/fill (kills the ~71k–232k per-frame `NSBezierPath` allocations) and
drop the dead `intersects` test. Separately, reconsider the 24→11px density flip
— at <50% the dense dots are only 3–5px apart and barely visible, so the flip
buys little and causes the knee.

## 2. No viewport culling — the "rendering bottleneck" you sensed

Every card is a permanent live subview; there is **no `intersects(viewport)`
skip anywhere** on the reproject path (`BoardView.swift:508`). At 100% most
cards sit off-screen and AppKit skips them; zooming out maps ~4× more world area
into view, so **~4× more WKWebView/terminal cards composite simultaneously**.
This is genuine GPU compositing cost — but it rises **monotonically as 1/zoom²**,
it is **not** a sharp 50% knee (50% is just where it reaches ~4× the 100%
baseline). It compounds the grid cost when zoomed out.

**Fix (medium confidence):** explicit viewport culling — hide offscreen cards
with `isHidden` (keep the view **alive** so a WKWebView keeps scroll position
and a SwiftTerm keeps receiving PTY output; do **not** `removeFromSuperview`).
For very dense low-zoom boards, the dormant semantic-zoom "locard" path
(`CardView.swift:434`, force-disabled at `BoardView.swift:76`/`:680`) could swap
live cards for cheap name+status chips below a zoom threshold — but that is a UX
reversal of the documented infinite-canvas model and is out of scope unless we
choose it deliberately.

## 3. Per-frame tax — why *all* movement feels heavy

These fire on **every scroll event** regardless of zoom (flat w.r.t. zoom):

- **`persistLayout` runs on every scroll delta.** `scrollWheel` calls
  `onLayoutChanged?` unconditionally (`BoardView.swift:653`) — unlike `magnify`,
  which commits only on `.ended`. That rebuilds the full layout snapshot
  (`board.boardDocPaths.sorted()` afresh each event, term/shelf/dock arrays),
  **msgpack-encodes it synchronously on the main thread**, and writes an IPC
  frame to the daemon — per scroll delta. (There is already a `TODO(perf)` at
  `AppController.swift:351`.) **Fix:** debounce (trailing ~200ms) or persist on
  scroll phase `.ended`/momentum `.ended`, flushed on resignActive/terminate and
  board switch.
- **`refreshWayfinding` runs twice per event.** `reprojectAll` fires
  `onCardsChanged` (`BoardView.swift:514`) *and* `scrollWheel` fires
  `onViewportChanged` (`:652`); both are wired to `refreshWayfinding`
  (`RootView.swift:109-110`). Each rebuilds the minimap (all card rects) and
  **tears down + recreates all offscreen-hint pill `NSView`s**
  (`OffscreenHints.swift:52-87`) and iterates all cards
  (`AppController.swift:1659`). **Fix:** coalesce to one refresh per frame
  (dirty flag / display-link); don't fire `onCardsChanged` on a pure pan (the
  card *set* didn't change, only the viewport); diff the pills instead of
  rebuilding.
- **A fresh `DateFormatter` per provenance edge, every pan frame.**
  `recomputeEdges` → `edgeLabel` allocates and configures a new `DateFormatter`
  per doc edge (`AppController.swift:2417`) — ICU setup is notoriously
  expensive. **Fix:** cache one shared formatter; better, the label is
  viewport-invariant, so recompute labels only on card-set/`lastOpenedMs`
  change and update only projected geometry on pan.
- **`updateLocards` loops all cards every frame** to set a value that never
  changes (locards are off) (`BoardView.swift:679`). **Fix:** remove from the
  per-frame path.
- **`refreshFloatingClose` does an O(cards) scan + coordinate-convert every
  reproject** (`BoardView.swift:522`). **Fix:** recompute on focus change, not
  every pan.
- **`updateContentScaleIfNeeded` walks every card's full layer tree on every
  *zoom* step**, even when the computed scale is unchanged (it is constant below
  100%) (`BoardView.swift:578` → `CardView.swift:184`). Pan-gated correctly, so
  zoom-only. **Fix:** per-card early-return when `scale == pendingContentScale`.
- **Micro:** `project()` calls `setBoundsSize` unconditionally every frame
  (`BoardView.swift:619`); guard `if card.bounds.size != worldSize`. Low value
  (world size is constant except on resize) but cheap insurance.

---

## Verified non-issues (do not touch)

- **SwiftTerm does not re-measure cols/rows on pan/zoom** — the crib comment at
  `BoardView.swift:608-616` is correct; bounds stay world-fixed, so the terminal
  only re-measures on an actual resize (`CardChrome.swift:476`).
- **No Auto Layout inside cards** — all manual frame-setting, no constraint
  solve on frame change (`CardView.swift:506`). Deliberate and correct.
- **`restack()`** (removeFromSuperview+addSubview per card) is O(N) but fires
  only on add / gesture-commit, **not** on the pan/zoom frame
  (`BoardView.swift:498`).

## Refuted hypotheses

- **"The zoom animation's `asyncAfter(1/60)` self-rearming chain is the
  bottleneck."** Refuted — `animateViewport` is reached **only** via `flyTo`
  (⏎/esc fly-to), an occasional discrete keyboard action. The continuous
  pan/zoom hot path is `scrollWheel`/`magnify`, which reproject synchronously in
  the event callback. (A display-link rewrite would still smooth the fly
  animation, but it is not the movement-time cost.)
- **"`applyDocZoomScale` re-rasterizes WebKit on pan."** Refuted — double-gated:
  zoom-change gated upstream (`updateContentScaleIfNeeded`) and scale-change
  gated internally (`DocWebView.swift:121`). The doc device-scale override is
  constant below 100% zoom, so it never re-rasters on the way down.

---

## Fix plan (one commit each, ranked)

| # | Fix | Kind | Confidence | Notes / risk |
|---|-----|------|-----------|--------------|
| 1 | Grid → GPU tiled/pattern layer (interim: single batched fill + drop `intersects`); revisit 24→11px flip | refactor (visual-preserving) + tuning | high | Primary. Kills the 50% cliff. Verify crispness at all zooms. |
| 2 | Debounce `persistLayout` on pan (commit on `.ended`/trailing timer) | behavior change | high | Flush on resignActive/terminate/board-switch so last position isn't dropped. |
| 3 | Coalesce wayfinding to one refresh/frame; stop firing `onCardsChanged` on pure pan; diff offscreen pills | refactor | high | Pure cleanup; no UX change. |
| 4 | Edges: cache shared `DateFormatter`; recompute labels on card-set change only; geometry-only on pan | refactor | high | |
| 5 | Viewport culling — `isHidden` offscreen cards (keep views alive) | behavior change (perf) | medium | Keep WKWebView scroll + SwiftTerm PTY alive; cull by `isHidden`, never remove. |
| 6 | Content-scale: per-card early-return when scale unchanged | refactor | high | Zoom-only path. No crispness regression (unchanged value). |
| 7 | `refreshFloatingClose`: recompute on focus change, not every reproject | refactor | medium | |
| 8 | Remove `updateLocards` from per-frame path (dead loop) | cleanup | high | Locards off in this model. |
| 9 | Guard `setBoundsSize` on size change | refactor | high | Micro; cheap insurance. |

**Testability.** The app layer is not unit-tested (only TarmacKit is). Extract
the pure decision logic into TarmacKit and unit-test it there: the
visible-card/culling predicate (#5), the dot-lattice visible-range computation
(#1), and the pan-commit gating (#2). The rest is verified by instrumentation +
manual run, not unit tests.

## Instrumentation — done (`PerfTrace.swift`)

The branch is named for profiling — measure before/after so each fix is
justified by numbers, not assertion. Implemented as a removable two-channel
profiler (`app/Sources/TarmacApp/PerfTrace.swift`):

- **os_signpost** intervals/events (always live, near-free) around `draw(_:)`
  (with the dot count `gridDots`), `reprojectAll`, `recomputeEdges`, and
  `persistLayout` — record against subsystem `dev.tarmac.perf` in Instruments.
- A **stderr aggregator** behind `TARMAC_PERF=1` that prints rolling
  n/mean/p95/max per key, plus `visibleCards`/`totalCards` gauges (the 1/zoom²
  curve and the culling headroom for #5).
- A scripted **benchmark** behind `TARMAC_PERF_BENCH=1`: populates ~42 synthetic
  cards, sweeps zoom 1.0 / 0.51 / 0.49 / 0.28 forcing a synchronous grid redraw
  per pan step, and prints one labelled line per level — no GUI interaction
  needed (synthetic trackpad events get dropped without an Accessibility grant).
  Drives `reprojectAll` directly, never persists. `TARMAC_PERF_BENCH=1 make run`,
  or run the binary directly for an isolated, daemon-less capture.

### Measured baseline (2026-06-16, `TARMAC_PERF_BENCH`, 80 panned frames/level, 42 cards)

| zoom | grid | `gridDots` | `draw` mean (p95 / max) | `reproject` mean | `edges` mean | visible / total |
|------|------|-----------|-------------------------|------------------|--------------|-----------------|
| 1.00 | 24px | 1,440  | **1.97ms** (2.2 / 2.3)   | 0.76ms | 0.02ms | 8 / 42  |
| 0.51 | 24px | 5,225  | **7.80ms** (8.3 / 13.7)  | 0.93ms | 0.03ms | 22 / 42 |
| 0.49 | 11px | 26,137 | **40.51ms** (43 / 47)    | 0.93ms | 0.03ms | 23 / 42 |
| 0.28 | 11px | 79,183 | **128.85ms** (159 / 263) | 1.81ms | 0.03ms | 40 / 42 |

What the numbers settle:

- **The grid IS the bottleneck.** `draw` dwarfs `reproject` by 20–70×. The
  0.50 threshold flip (24→11px) makes 0.51→0.49 jump `draw` **7.8ms → 40.5ms
  (5.2×)** for a **5× dot-count jump** — this is the "broken at 50%" cliff,
  measured. By 0.28 the grid alone is ~129ms/frame (~8fps).
- **Culling (#5) is real but secondary.** Only 8/42 cards are on-screen at 100%
  (81% cullable), yet `reproject` stays sub-2ms even at 40 visible — so #5 is a
  smaller win than the grid, and helps least when zoomed out (where everything's
  on-screen and the grid dominates anyway). NB: these are *bare* cards; real
  WKWebView/terminal reprojection is heavier than measured here.
- **`edges` geometry is negligible** (~0.03ms) — but the synthetic docs carry no
  label, so this does *not* exercise the per-edge `DateFormatter` alloc (#4);
  that cost only appears with real labelled doc cards.
- **`persist` isn't in the sweep** (it drives `reprojectAll` directly to avoid
  writing junk layouts); capture it from a real `TARMAC_PERF=1 make run` session.

Re-run this same benchmark after each fix for an apples-to-apples before/after.

---

## Appendix — full verified audit (31 confirmed)

Severities are *post-verification* (some finder severities were downgraded by
the adversarial pass). `knee-at-50` = discontinuous jump at the threshold;
`monotonic-worse` = rises continuously as you zoom out; `flat` = zoom-independent.

| Sev | Zoom-out | /frame | Finding | Location |
|-----|----------|--------|---------|----------|
| high | monotonic-worse | yes | Crossing 0.5 flips grid to 11px lattice → ~5x more per-frame dot fills (each its own NSBezierPath alloc) | BoardView.swift:670-673 (updateGridDensity) + draw(_:) 701-735, spacing select at 705, dot loop 720-734 |
| high | knee-at-50 | yes | Semantic-zoom density flip multiplies dot count by (24/11)^2 = 4.76x in a single frame at the 50% threshold | BoardView.swift:705-708 (worldSpacing flip), BoardModel.swift:55,65 (isSemanticZoom = zoom < 0.5) |
| high | knee-at-50 | yes | Worst-case ~232,000 NSBezierPath allocations per frame just above the viewSpacing>=3 cutoff (zoom ~ 0.273) | BoardView.swift:708 (guard), 721-734 (nested while loop), 727-729 (per-dot NSRect + NSBezierPath(ovalIn:) + fill) |
| medium | flat | sometimes | persistLayout (full snapshot + sync msgpack encode + IPC) fires unguarded on every scrollWheel pan event | BoardView.swift:653 (onLayoutChanged in scrollWheel) |
| medium | flat | yes | refreshWayfinding runs at least TWICE per scroll event (redundant minimap + offscreen-hint rebuild) | BoardView.swift:514 (onCardsChanged inside reprojectAll) and BoardView.swift:652 (onViewportChanged) |
| medium | monotonic-worse | yes | recomputeEdges + EdgeLayerView full redraw + grid dot redraw composite every pan with no incremental invalidation | BoardView.swift:625-636 (recomputeEdges -> setEdges), EdgeLayerView.swift:40-75 (setEdges -> needsDisplay, draw loops all edges), BoardView.swift:651 & 701-735 (needsDisplay -> draw dot grid) |
| medium | flat | sometimes | updateContentScaleIfNeeded re-rasterizes every card on EVERY zoom step (full layer-tree walk + WebKit device-scale push) | BoardView.swift:578-587 (called from reprojectAll, line 510) |
| medium | flat | yes | reprojectAll rebuilds the entire wayfinding chrome (minimap + offscreen hints) TWICE per animation step | BoardView.swift:508-515 (onCardsChanged at 514, onViewportChanged at 230) |
| medium | knee-at-50 | yes | Entire grid recomputed from scratch on EVERY pan and zoom frame — no partial invalidation, no cached/layer-tiled grid | BoardView.swift:261 (zoom), 651 (pan/scrollWheel), 686 (layout), 672 (density flip), 701-735 (full redraw) |
| medium | flat | yes | minimap.update rebuilds ALL card rects and forces a full redraw on every refresh | Minimap.swift:48-67 (update + recomputeMapping) |
| medium | flat | yes | recomputeEdges rebuilds the entire provenance edge set on every reproject and forces an edge-layer redisplay | BoardView.swift:625-636 (recomputeEdges), called from reprojectAll BoardView.swift:512 |
| medium | flat | yes | Three independent NSView redisplays + full SwiftTerm/card reproject forced every frame, multiplied by the 2x refresh | BoardView.swift:651 (board needsDisplay), Minimap.swift:52, EdgeLayerView.swift:42 |
| medium | flat | yes | No viewport culling: every card is a permanent live subview that always composites | BoardView.swift:54-55, 65-82 (addCard), 84-91 (removeCard), 508-515 (reprojectAll), 617-620 (project) |
| medium | flat | yes | reprojectAll fires on EVERY pan/zoom frame and touches all cards, re-laying-out the whole tree | BoardView.swift:643-654 (scrollWheel), 245-264 (zoom), 657-664 (magnify), 212-240 (animateViewport, 18 frames), 508-515 (reprojectAll), 600-620 (reproject/project) |
| medium | flat | sometimes | frame≠bounds scale transform on each card layer — applied even to WKWebView doc cards | BoardView.swift:600-620 (project + setBoundsSize), 122-145 (worldToView rect), CardView.swift:129 (wantsLayer), DocWebView.swift:43-58 (WKWebView host), 117-148 (_setOverrideDeviceScaleFactor) |
| medium | monotonic-worse | sometimes | Zoom-out lands ~4x more cards on-screen → compositing cost rises ~1/zoom² (monotonic, not a 50% knee) | BoardView.swift:508-509 (no visible-set filter), 617-620 (every card composited under scale), CardView.swift:129/135/460 (each card multiple wantsLayer subtrees) |
| low | flat | yes | No viewport culling — every card is reprojected on every pan, including fully offscreen cards | BoardView.swift:508-515 (reprojectAll), 617-620 (project), 600-606 (reproject) |
| low | flat | yes | recomputeEdges allocates a fresh DateFormatter per doc edge on every reproject (every pan) | BoardView.swift:512 & 603 (recomputeEdges call), 625-636 (recomputeEdges), AppController.swift:2417-2426 (edgeLabel via edgeLabelProvider) |
| low | flat | yes | refreshFloatingClose does an O(cards) scan + a coordinate-convert containment test on every reproject | BoardView.swift:513 & 604 (call), 522-549 (refreshFloatingClose) |
| low | flat | sometimes | updateContentScaleIfNeeded is correctly zoom-gated (NOT a pan-path cost) — confirms the per-pan cost is reprojection/persistence, not content rescale | BoardView.swift:578-587 (updateContentScaleIfNeeded), 510 (called from reprojectAll) |
| low | flat | yes | updateLocards iterates all cards every step to set a value that never changes (dead per-frame loop) | BoardView.swift:679-681 (called every tick at 228 and in zoom(by:) 260) |
| low | flat | yes | recomputeEdges + refreshFloatingClose run every step inside reprojectAll (per-frame coordinate converts and array rebuild) | BoardView.swift:512-513 (in reprojectAll) |
| low | flat | yes | refreshWayfinding runs TWICE per pan/zoom event (onCardsChanged + onViewportChanged both fire) | BoardView.swift:508-515 (reprojectAll) and BoardView.swift:643-654 (scrollWheel) |
| low | flat | yes | offscreenHints() iterates ALL cards building Hint structs every refresh (twice per frame) | AppController.swift:1659-1679 (offscreenHints) |
| low | flat | yes | OffscreenHints.rebuild tears down and re-creates ALL pill NSViews every refresh | OffscreenHints.swift:52-87 (update/rebuild) |
| low | none | no | restack() does removeFromSuperview+addSubview on every card — a per-add / per-gesture-commit O(N) spike, NOT a pan/zoom-frame cost | BoardView.swift:498-504 (restack), 71 (addCard→restack), 432 (onFrameCommitted→restack), 483-495 (raiseToFront, guarded by isGesturing), 107-118 (setTerminal→restack) |
| low | flat | yes | setBoundsSize() unconditionally dirties CardView layout on EVERY pan/zoom frame (even when world size is unchanged) | BoardView.swift:619 (call) → CardView.swift:506-519 (CardView.layout) |
| low | flat | sometimes | frame= assignment forces CardView.layout() on every ZOOM frame (size changes); harmless on pan | BoardView.swift:618 → CardView.swift:506 |
| low | flat | sometimes | applyContentScale (full layer-tree walk) is correctly gated to zoom-change only — NOT per pan frame | BoardView.swift:578-587 (updateContentScaleIfNeeded) → CardView.swift:184-195 (applyContentScale) |
| non-issue | none | no | SwiftTerm does NOT re-measure cols/rows on pan/zoom — crib comment verified correct | BoardView.swift:614-615 (claim) → CardChrome.swift:476-484 (TerminalBodyView.layout) → AppController.swift:21,542 (terminalSizeChanged) |
| non-issue | flat | no | No Auto Layout constraints inside the card — manual frame-setting, no constraint re-solve on frame change | CardView.swift:506-537 (layout/layoutHandles) |
