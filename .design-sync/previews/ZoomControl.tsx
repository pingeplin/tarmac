// Authored previews for ZoomControl — the bottom-left − / readout / + / ⊡ fit
// cluster (desktop/src/ui/ZoomControl.tsx). It is purely presentational over a
// `zoom` number and three callbacks — no min/max-zoom awareness or disabled
// affordance lives in the component itself (BoardEngine clamps the value
// upstream), so the only real variant axis is the live readout at a few
// realistic zoom levels: `formatZoomPct` rounds `zoom*100` to the nearest
// percent, half away from zero.
//
// GOTCHA (see DocCard.tsx for the full writeup): `.zoom-control` is
// `position: absolute; left: 12px; bottom: 12px` — it's meant to sit pinned to
// a corner of `.board`. The single-story capture wrapper has zero intrinsic
// height (it only contains this one absolutely-positioned child), so a bare
// `<ZoomControl />` resolves `bottom: 12px` against a 0-height box and renders
// almost entirely above the viewport (only a sliver at the very top visible).
// Wrapping in a plain sized `position: relative` box gives it a real corner to
// pin against.
import { ZoomControl } from "tarmac-app";

const noop = () => {};

const frame = { position: "relative" as const, width: 220, height: 90 };

/** Near the board's minimum practical zoom — most cards tiny/off-canvas. */
export function ZoomedOut() {
  return (
    <div style={frame}>
      <ZoomControl zoom={0.25} onZoomIn={noop} onZoomOut={noop} onFit={noop} />
    </div>
  );
}

/** A non-round mid zoom (matches the kit-fixtures.mjs fixture value) — the
 * common everyday reading level, one card comfortably filling the view. */
export function Default() {
  return (
    <div style={frame}>
      <ZoomControl zoom={1.25} onZoomIn={noop} onZoomOut={noop} onFit={noop} />
    </div>
  );
}

/** BoardEngine's MAX_ZOOM (3.0, see desktop/src/kit/docZoom.ts) — the top of the
 * board's zoom range. */
export function MaxZoom() {
  return (
    <div style={frame}>
      <ZoomControl zoom={3} onZoomIn={noop} onZoomOut={noop} onFit={noop} />
    </div>
  );
}
