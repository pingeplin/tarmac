# Handoff: crisp card text under board zoom (Tauri)

**For:** Sonnet implementer. **Area:** `desktop/` (Tauri 2 + React + xterm).
**Deliver a SOLID design, not point hacks.** Centralize; no scattered transform math per card.

## Problem
The board is one webview. `BoardEngine` writes a single `transform: translate() scale(zoom)`
on the world layer (`BoardEngine.ts:244`); all cards are absolutely positioned inside it.
That layer rasterizes at 1× and the GPU upscales it, so above zoom 1.0 all card text/glyphs
go soft. Already acknowledged in-code (`BoardEngine.ts:44` "cards bitmap-scale"). This is the
single-webview analog of the Swift fix (commit `12c537f`), whose native `WKWebView` device-scale
SPI does **not** apply here — there are no nested webviews.

## Goal
Re-rasterize card content at the on-screen (zoomed) resolution so text is crisp, **without
reflow** and **without regressing zoom smoothness**. Covers **all** card types.

## Hard constraints
- **No reflow.** Keep the pure view-transform zoom model (whiteboard UX invariant). Wrap points,
  cell grid, and layout must be pixel-identical before/after the fix at a given zoom.
- **Crisp-on-settle.** Keep the cheap GPU-scaled transform during an active gesture; re-rasterize
  only after zoom settles (debounce, ~150ms). Don't re-raster every frame.
- Zoom range stays 0.1–3.0; only oversample when it helps (zoom > 1; downscale path is already fine).

## Approach (recommended)
**One source of truth, per-card-type adapters.**
1. `BoardEngine` owns a derived **rasterScale** = settled zoom, **quantized** (e.g. snap to coarse
   steps) and **capped at 3×** (matches Swift's cap; bounds memory/re-raster churn). Expose it as a
   single signal / CSS var. Cards subscribe — they never re-derive zoom.
2. **DOM cards (doc/markdown + chrome): counter-scale.** Render the card's content layer at
   `×rasterScale` intrinsic size + font, then `transform: scale(1/rasterScale)`. Net visual size is
   unchanged but glyphs raster at device resolution. Scale **every** dimension by the **same**
   factor (box, font, padding, line-height) so wrap points are provably identical → no visible reflow.
3. **Terminal cards (xterm): oversample, don't counter-scale a bitmap.** Drive xterm to re-render at
   `DPR × rasterScale` (raise the renderer's effective device pixel ratio / cell metrics) so the
   canvas backing is zoom-native, then the world transform presents it at net 1×. **Keep cols×rows
   fixed** — change pixel density, not cell count. Re-render on settle only. Mind the existing
   screen-pixel/DPR logic in `TerminalCard.tsx`.

## SOLID guardrails
- Single responsibility: rasterScale derivation lives **only** in `BoardEngine`; cards consume it.
- Open/closed: a small shared contract (e.g. `applyRasterScale(scale)`); DOM card and terminal card
  each implement one adapter behind it. Adding a future card type = one adapter, no engine edits.
- No magic numbers sprinkled in `CardShell`/components — one util/hook, named constants.

## Acceptance
- Doc + terminal text visibly crisp at zoom 1.5×–3× after the gesture settles.
- Zero reflow: a doc's line breaks and the terminal's grid are identical pre/post fix at any zoom.
- No new jank during active pinch/⌘-scroll (verify against the known zoom-perf cliff).
- Below ~1× unchanged. No leaked listeners; rasterScale updates are debounced and idempotent.

## Verify
`cd desktop` build + run; zoom a doc card and a live terminal to 2–3×, confirm crispness on settle,
confirm grid/wrap unchanged, watch for gesture jank. (Swift reference for typography parity only:
body 16px to match the terminal — optional, cosmetic.)
