// Authored previews for MinimapOverlay — the bottom-right minimap
// (desktop/src/ui/MinimapOverlay.tsx). It maps every card's world rect plus the
// viewport's world rect into a fixed 132×88 pane (MAP_W/MAP_H are baked into the
// component, not props) via the already-ported+tested minimapMapping/boundingBox
// pure math in kit/boardWayfinding.ts — so the only real variant axis is the
// `items`/`viewportWorldRect` world layout: how many cards, their signal mix, and
// how the viewport rect relates to them (fully containing them vs. zoomed into
// one). Base layout matches the hand-authored desktop/scripts/kit-fixtures.mjs
// MinimapOverlay fixture (mixed live/none/bell + an overlapping viewport); the
// other two stories sweep the shape of `boundingBox` union that the component's
// own doc comment calls out as a deliberate behavior (viewport unioned into the
// world box so its box stays visible even panned past every card).
//
// GOTCHA (see DocCard.tsx for the full writeup): `.minimap` is `position:
// absolute; right: 12px; bottom: 12px` with its own fixed 132×88 size — the
// box itself won't collapse to a sliver (unlike inset:0/percent-centered
// chrome), but `right`/`bottom` still resolve against the nearest positioned
// ancestor, which is a 0-height div in the bare single-story wrapper — so
// without a sized `position: relative` ancestor the pane silently renders
// pinned to the very top of the page instead of a boardlike bottom-right
// corner. Wrapping in a `.board`-sized box (matching the fixture's plausible
// board dimensions) reproduces the real corner-pinned look.
//
// SECOND GOTCHA (learned this wave — not in DocCard's writeup): the capture
// tool's raw screenshot viewport is a fixed 900×700px, well under a real
// board window. A wrapper wider/taller than that clips silently (no error) —
// a `right: 12px`-pinned box in a 960px-wide wrapper renders mostly off the
// right edge of the 900px capture. Keep story wrapper dimensions <= ~860×600
// so board-corner-pinned chrome stays fully inside the captured frame.
import { MinimapOverlay } from "tarmac-app";

const noop = () => {};

const frame = { position: "relative" as const, width: 800, height: 560 };

/** The steady-state look: three cards (live/none/bell) spread around a
 * viewport rect that overlaps most of them — matches the kit-fixtures.mjs
 * MinimapOverlay fixture exactly (same items + viewport). */
export function Default() {
  return (
    <div className="board" style={frame}>
      <MinimapOverlay
        items={[
          { worldRect: { x: 0, y: 0, w: 360, h: 220 }, signal: "live" },
          { worldRect: { x: 420, y: 40, w: 360, h: 480 }, signal: "none" },
          { worldRect: { x: -200, y: 300, w: 240, h: 160 }, signal: "bell" },
        ]}
        viewportWorldRect={{ x: -100, y: -60, w: 900, h: 640 }}
        onJump={noop}
      />
    </div>
  );
}

/** Zoomed in on a single card: the viewport rect is small and sits fully
 * inside one card's world rect, while two other (quiet) cards sit off to the
 * side — exercises the mapping when the viewport, not the cards, is the
 * tightest box on one axis and the cards dominate on the other. */
export function ZoomedIntoOneCard() {
  return (
    <div className="board" style={frame}>
      <MinimapOverlay
        items={[
          { worldRect: { x: 0, y: 0, w: 800, h: 500 }, signal: "bell" },
          { worldRect: { x: 900, y: 40, w: 320, h: 220 }, signal: "none" },
          { worldRect: { x: 900, y: 320, w: 320, h: 220 }, signal: "live" },
        ]}
        viewportWorldRect={{ x: 250, y: 150, w: 220, h: 150 }}
        onJump={noop}
      />
    </div>
  );
}

/** No cards at all (fresh/empty board) — per the component's own doc comment,
 * the viewport rect is unioned into the world box on its own so the viewport
 * outline still renders (filling nearly the whole pane) even with zero card
 * rects to draw. */
export function EmptyBoard() {
  return (
    <div className="board" style={frame}>
      <MinimapOverlay items={[]} viewportWorldRect={{ x: 0, y: 0, w: 1200, h: 800 }} onJump={noop} />
    </div>
  );
}
