# Unified Screen-Space `.card-layer` for the Tauri Board

**Date:** 2026-06-28
**Status:** proposed
**Author:** EP Lin
**Doc type:** ADR

## TL;DR

Collapse the board's two sibling card layers (`.world` for terminals, `.doc-layer` for docs) into **one screen-space `.card-layer`** holding every card as a wrapper div carrying `zIndex:c.z`. The doc wrapper-box mechanism (`docZoom.ts`) generalizes to all cards; terminals gain a two-node wrapper (outer screen-space translate + inner `scale(var(--zoom))` div) and leave `.world`. Cross-type focus-on-top then works for free — the model already computes it; only the DOM betrays it. The hot path is unchanged: it is already CSS-var-driven and O(1) in card count.

## Context / problem

Cross-type "focused card on top" is **structurally impossible today**. The selection model is already correct — `topZ` folds `Math.max` across all kinds (`model.ts:100`), and `onCardGrab` bumps the grabbed card to `topZ+1` cross-type for any type (`App.tsx:1439`). The DOM defeats it:

- `Board.tsx:133` renders `.world` (terminals); `Board.tsx:164` renders `.doc-layer` as the **next sibling** in the same `.board` stacking context.
- `apply()` writes `transform: translate(...) scale(zoom)` on `.world` (`BoardEngine.ts:258`) → `.world` becomes its own stacking context, effective `z-index:auto`. `.doc-layer` (`theme.css:119`) also `z-index:auto`.
- Within one stacking context, `z-index:auto` positioned elements paint in **DOM source order**. `.doc-layer` is second → **docs always paint above all terminals**, whatever their integer `z`.

A grabbed terminal gets the highest `z` (`CardShell.tsx:170`), but that `z` is scoped *inside* `.world` and has zero effect against `.doc-layer`.

## Decision

One screen-space layer, `.card-layer` (`position:absolute; inset:0; pointer-events:none`, `.card{pointer-events:auto}`), replacing `.doc-layer` and holding **all** cards as wrapper divs with `zIndex:c.z` in a single stacking context. Focus-on-top works across types with no model change.

**Reused unchanged:** the four-var hot path (`--zoom/--world-tx/--world-ty/--grid-size`, `BoardEngine.ts:254–273`); `docWrapperBox()`/`docCardVars()` (`docZoom.ts:46,64`) — now the wrapper formula for *every* card; `CardShell` `inWrapper` branch (`CardShell.tsx:167`, both types `inset:0`); culling (`applyCull`), `worldToView`, rasterScale settle, the doc prose oversample→downscale subtree, persistence (`layoutTiles.ts` round-trips `z` for both kinds), and the BCR override formula (`TerminalCard.tsx:148`).

**Newly built — the terminal wrapper (two nested nodes):**

| Node | Style | Role |
|---|---|---|
| Outer (new) | identical to `docWrapperBox()`: `width:calc(var(--card-w)*var(--zoom))`, translate-only off world vars, `zIndex:c.z` | cullable element + z-participant; terminals gain per-card `--card-x/y/w/h` |
| Inner (new) | `width:var(--card-w); height:var(--card-h)` (**zoom-free**) + `transform:scale(var(--zoom)); transform-origin:0 0` | replaces `.world`'s role; reads the same `--zoom` the engine already writes (`BoardEngine.ts:265`) → all inner divs scale per frame at O(1), no per-card JS |

`CardShell`, `.term-host`, and `.term-raster-clip/wrapper` move **unchanged** inside the inner div; `TerminalCard` passes `inWrapper={true}`. The inner box is zoom-invariant, so xterm's ResizeObserver stays silent on zoom and `cols×rows` is preserved.

**Deliberate asymmetry — do NOT unify card interiors.** Terminals magnify chrome+content together via the inner `scale(zoom)` div (crisp at canvas level via rasterScale). Docs use a real-px box with calc-scaled chrome + an oversample→downscale prose subtree (a plain `scale(zoom)` would blur prose, per `docZoom.ts:6`). The wrapper/z layer unifies; the interiors must stay divergent.

**Chrome scoping.** Terminals in the inner `scale(zoom)` div get border/header/radius magnified for free — no calc-`var(--zoom)` chrome. The `.doc-layer .card` chrome block (`theme.css:370`) must stay **doc-scoped** (gate on `.doc-card`), not be blanket-renamed to `.card-layer .card`, or terminal chrome is double-scaled.

## Alternatives considered

**Keep two layers + a manual z-bridge.** Compute, per frame, which layer should paint on top and reorder the two layer nodes (or toggle `isolation`). Rejected: only resolves whole-layer ordering, never *interleaving* — a doc behind one terminal and in front of another is unrepresentable. The bug is that z is layer-local; this keeps it layer-local.

**Promote docs into `.world` instead of terminals out.** Docs become world children, magnified by `scale(zoom)`. Rejected: a `scale(zoom)` over the doc subtree **upscales** the prose raster and blurs it (the exact failure `DOC_OVERSAMPLE_K` exists to avoid, `docZoom.ts:19`). Crispness is a hard product invariant; this trades it away.

**Status quo + per-type z bands** (docs always above terminals). Rejected: it *encodes the current bug as policy*. Grabbing a terminal can never raise it above a doc — contradicting the single-z focus model the rest of the app already implements.

## Trade-offs & load-bearing assumption

- **The trade-off:** the merge is *structural only* — we buy correct cross-type z by accepting permanently divergent interiors (terminal `scale(zoom)` vs. doc oversample→downscale) plus a second wrapper node per terminal. Interior asymmetry is the price of keeping the crispness invariant and the O(1) hot path.
- **THE assumption: the pan/zoom hot path stays cheap because it is already CSS-var-driven.** `apply()` writes one transform + four vars per frame (`--zoom/--world-tx/--world-ty/--grid-size`, `BoardEngine.ts:254`); doc wrappers already reposition purely via `calc()` with zero per-card JS. Generalizing the wrapper means terminal inner divs resolve `scale(var(--zoom))` on the compositor for free. **Validate:** profile pan/zoom with N terminals + N docs before/after; assert no per-card JS on frame (only committed frame changes write `--card-*`); watch the dot-grid redraw cliff from prior perf work.
- **Cost:** terminals gain per-card `--card-x/y/w/h` React writes on frame-change — already paid by docs.
- **Hard constraint:** the inner div **must** size `var(--card-w)` (zoom-free), never `calc(--card-w*--zoom)` or a `%` of the zoom-reactive outer wrapper — else the host box becomes zoom-reactive and `fit()`/PTY-resize fires every zoom frame for N terminals.

## Invariants that must not break

- **Zoom never changes a terminal's layout box** — `cols×rows = f(frame.w,h,fontSize,padding)`, zoom-independent. Inner div stays `var(--card-w)`.
- **BCR effective scale = zoom/rs** at the xterm element (`TerminalCard.tsx:150`), preserved by keeping a per-card `scale(zoom)`. Any added/removed transform between `.card-layer` root and `term.element` breaks selection.
- **`fit()` fires only on** resize, dock/undock, hidden→visible — never on zoom/rasterScale. The 0×0 guard must still fire on `display:none` warm boards under the new nesting.
- **No-reflow doc zoom:** `docProseScaler()` stays the only `--zoom` reference in the doc subtree; **no `will-change`** anywhere (pins the raster → permanent blur).
- **CJK/IME:** `isComposingKey` (`imeGuard.ts:9`) stays the sole app-level gate; position/zoom-independent.
- **Culling = `visibility:hidden`** (never `display:none`); cullable target moves to the outer wrapper for terminals.
- **Persistence/z:** shared `z` namespace, restored verbatim (`layoutTiles.ts`); `zIndex:c.z` goes on the **outer** wrapper only (inner/`.card` are isolated contexts).
- **EdgeLayer co-location:** edges still paint behind all cards; endpoints are reprojected world→screen and follow the hot-path var writes via an imperative `<path>` `d` update in `apply()` (no `.world`).

## Decision points (resolved)

- **EdgeLayer — Option B (DISSOLVE `.world`).** `.world` is removed entirely; terminals leave it and edges reproject to screen space. SVG `d` accepts no `calc()`/`var()`, so rather than a hot-path React render (anti-pattern) the edge endpoints update **imperatively off the same pan/zoom hot path**: `apply()` reprojects each `M…L…` from world-space card centers (`provenance.ts` formula, unchanged) to screen space and writes the `d` string directly to the `<path>` via a ref — no React state/render on the frame. The "zero per-card JS / zero React on the frame" invariant holds; the cost is one new imperative DOM write per edge in `apply()` (see Risks).
- **Background-press guard** (`Board.tsx:126`) must also catch `.card-layer` (now the gap-filler); the SVG is `pointer-events:none`.
- **z node placement:** outer wrapper, settled above.
- **Saved-board migration — RESTORE VERBATIM.** No migration code: saved `z` is restored exactly, so existing boards render identically (docs stay above terminals) until the user next grabs a card, which re-orders as expected. Zero upgrade risk.
- **Dead code — REMOVED (done, commit `a682c6f`).** `docSuspend.ts` (+ its test) and the `--grid-x`/`--grid-y` vars are deleted on this branch; build + 264 tests green. Correction to the prior framing: `--grid-x/y` were *unconsumed* (no CSS rule read them), not duplicates of `--world-tx/ty`.
- **Docked-terminal BCR overcorrection — IN SCOPE (fix in this PR).** While docked, the host is reparented out of the board transform so its effective scale is 1, but `fakeBCR` still divides by `s = zoom` (only `rs` is pinned to 1, `TerminalCard.tsx:93,150`) → selection mis-lands when the board is zoomed ≠ 1. Fix: skip the override when docked (return the untouched rect). Needs a `dockedRef` mirroring `rsRef`, since the mount-time effect closure captures `docked` stalely.
- **`firstFreeSlot` placement — DOCS-ONLY (no change).** New-card placement stays doc-scoped (`placement.ts`); it is *not* made collision-aware across terminals despite the shared `.card-layer`. Terminals keep their existing placement path; the unified layer is purely visual/z-order here.

## Risks & verification plan

**Fragile surfaces:** zoom-reactive inner-div size → `fit()`/PTY-resize spam during pinch (highest severity); a stray `will-change:transform` → permanent prose blur; un-gated `.card-layer .card` chrome → wrong terminal border/header; stale `Board.tsx:126` guard → selection no longer clears; React key instability → with one layer, `z-index` is the *only* ordering, so a stale key is now visible; **imperative edge-`d` update in `apply()`** → new hand-written DOM code on the hot path (a fresh fragile surface): a missed ref, a stale card center, or an exception now silently desyncs edges from their cards or stutters the frame.

**Re-QA:**
- All **264** `src/kit` unit tests green (`docZoom`, `rasterScale`, `layoutTiles`, `cardChrome/resize/boardTransform`). (Was 267 before the `docSuspend` cleanup on this branch.)
- **Real `make run` on a 1× (non-Retina) monitor** — the regime where upscale blurs and downscale stays crisp: terminal text across rasterScale steps; doc prose across full zoom.
- Selection coords land on the correct cell at zoom∈{0.5,1,1.5,2,3}×rs, **including docked terminals**; IME/CJK into a zoomed terminal; dock/undock reparent; warm-board reveal fires `fit()` exactly once.
- Pan/zoom frame cost with N terminals + N docs (no per-card JS regression).
- Provenance edge endpoints stay glued to their term/doc centers across pan/zoom (imperative `d` update only — assert **no React render on the frame**, edges painted behind all cards).

**New tests:**
- `layoutTiles.test.ts` round-trip currently does **not** assert `z` — add it for term and doc tiles.
- Cross-type z ordering: doc `z=10` paints above term `z=5`; focused-on-top across types.
- A `termZoom` pure module (parallel to `docZoom`) emitting the terminal wrapper box + `--card-*` vars; assert **translate-only, zoom-free inner box** (mirrors `docZoom.test.ts` S1/S2/S6).
- Assert the product of transforms on the xterm element equals `zoom/rs` (guards the BCR contract); and that a **docked** terminal skips the override (effective `s=1`) even when the board zoom ≠ 1.

## Success criteria

- Grabbing any card raises it above all others regardless of type; verified by a cross-type z test and by hand.
- Zero per-card JS on the pan/zoom frame; profile parity with today.
- Terminal text and doc prose crisp across the full zoom range on a 1× monitor.
- Provenance edges stay co-located with their cards across pan/zoom with no `.world` and no React render on the frame.
- All 264 unit tests green; the four new tests added and passing.

## Open questions for the human

None — all decisions resolved (see *Decision points* above). Ready for `/spec`.
