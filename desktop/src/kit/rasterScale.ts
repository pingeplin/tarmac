// Per-card rasterization scale logic. BoardEngine owns the settled rasterScale and
// its settle-debounce; cards consume it via a prop passed from Board. All constants
// are named here — no magic numbers in card components or CardShell.
//
// Approach (per spec tauri-card-crispness-fix.md):
//   DOM cards  (DocCard): counter-scale — render content at ×rasterScale, apply
//     transform:scale(1/rasterScale) so visual size is unchanged but glyphs
//     rasterize at device resolution. Every dimension scaled by the same factor
//     so wrap points are provably identical (no reflow).
//   Terminal cards (TerminalCard): oversample — resize xterm into a rasterScale×
//     larger host with rasterScale× larger fontSize; the FitAddon recomputes the
//     same cols×rows (ratio unchanged); a counter-scale CSS transform brings the
//     card back to its original visual footprint. Canvas backing is rasterScale×DPR.

/** Quantization step: snap zoom to multiples of this to bound re-raster churn. */
export const RASTER_SCALE_STEP = 0.5;

/** Maximum rasterScale. Matches Swift's 3× cap; limits canvas memory. */
export const RASTER_SCALE_CAP = 3.0;

/** Debounce window before cards re-raster. GPU-scale during gesture, re-raster
 *  only after zoom settles. ~150ms matches Swift's settle heuristic. */
export const RASTER_SCALE_SETTLE_MS = 150;

/**
 * Derive the rasterScale for a given board zoom level.
 *
 * At zoom ≤ 1 the display is already downscaling and anti-aliasing is free —
 * no oversampling needed. At zoom > 1 snap to RASTER_SCALE_STEP increments
 * (to bound re-raster frequency) and cap at RASTER_SCALE_CAP.
 *
 * Examples (step = 0.5):
 *   zoom 0.8 → 1.0   (below 1, no oversample)
 *   zoom 1.0 → 1.0   (at 1, no-op)
 *   zoom 1.1 → 1.5   (ceil to next step)
 *   zoom 1.5 → 1.5
 *   zoom 1.6 → 2.0
 *   zoom 2.9 → 3.0   (cap)
 *   zoom 3.0 → 3.0
 */
export function deriveRasterScale(zoom: number): number {
  if (zoom <= 1) return 1;
  const snapped = Math.ceil(zoom / RASTER_SCALE_STEP) * RASTER_SCALE_STEP;
  return Math.min(RASTER_SCALE_CAP, snapped);
}
