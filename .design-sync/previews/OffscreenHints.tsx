// Authored previews for OffscreenHints — the click-through offscreen-signal
// pill overlay (desktop/src/ui/OffscreenHints.tsx). The component is a pure
// render over an already-laid-out `PlacedPill[]` (edge/arrow/label/left/top);
// all the interesting math (priority, edge projection, greedy anti-overlap
// stacking) lives in the tested kit/offscreenHints.ts `stackPills` and isn't
// exercised here — the variant axis for THIS component is just the visual
// shape of a placed-pill set: which edges are occupied, the bell/live signal
// styling split (border/label/arrow color swap — see chrome.css
// `.offscreen-hint.bell` / `.offscreen-hint.live`), and same-edge stacking.
// Default mirrors the hand-authored kit-fixtures.mjs OffscreenHints fixture
// exactly (same two pills); the other stories sweep edges the fixture doesn't
// cover (top/left) and a stacked-pill case exercising the `stackGap` nudging
// kit/offscreenHints.ts computes for multiple signals on the same edge.
//
// GOTCHA (see DocCard.tsx for the full writeup): `.offscreen-hints` is
// `position: absolute; inset: 0; pointer-events: none` and each `.offscreen-
// hint` pill is `position: absolute; left/top: <px>` in overlay-local
// coordinates — those pixel values are meaningless without a real-sized
// containing block behind `inset: 0`. The bare single-story wrapper has zero
// intrinsic height, so `inset: 0` collapses to a 0×0 box and every pill (even
// at left/top in the hundreds) clips to invisible. Wrapping in a `.board`-sized
// box big enough to hold every pill's left/top reproduces the real board
// viewport the overlay is designed to sit inside.
//
// SECOND GOTCHA (learned this wave — not in DocCard's writeup): the capture
// tool's raw screenshot viewport is a fixed 900×700px. Because this
// component's pill coordinates are literal overlay-local pixels (unlike
// DocCard/BoardSwitcher's percentage/inset-based chrome), a wrapper sized
// past 900×700 both clips AND makes the pill left/top values (originally
// picked against a wider "board") land far from the edge they're meant to
// hug. Keep the wrapper <= ~860×600 and re-derive every pill's left/top
// against that box's actual edges, rather than reusing the fixture's raw
// numbers verbatim.
import { OffscreenHints } from "tarmac-app";

const frame = { position: "relative" as const, width: 860, height: 600 };

/** The steady-state look: a bell pill pinned to the right edge and a live pill
 * pinned to the bottom edge — same two pills/signals as the kit-fixtures.mjs
 * OffscreenHints fixture, with left/top re-derived to hug this story's
 * 860×600 board edges instead of the fixture's wider assumed board. */
export function Default() {
  return (
    <div className="board" style={frame}>
      <OffscreenHints
        pills={[
          { cardId: "c1", signal: "bell", label: "shell", edge: "right", arrow: "→", left: 770, top: 120 },
          { cardId: "c2", signal: "live", label: "README.md", edge: "bottom", arrow: "↓", left: 300, top: 550 },
        ]}
      />
    </div>
  );
}

/** One occupied pill per edge (left/right/top/bottom), mixing both signal
 * classes, so all four arrow glyphs and both border/label/arrow color
 * treatments are visible at once. */
export function AllEdges() {
  return (
    <div className="board" style={frame}>
      <OffscreenHints
        pills={[
          { cardId: "left-1", signal: "live", label: "npm run dev", edge: "left", arrow: "←", left: 12, top: 280 },
          { cardId: "right-1", signal: "bell", label: "shell", edge: "right", arrow: "→", left: 770, top: 140 },
          { cardId: "top-1", signal: "live", label: "vitest", edge: "top", arrow: "↑", left: 380, top: 12 },
          { cardId: "bottom-1", signal: "bell", label: "claude · 14:02", edge: "bottom", arrow: "↓", left: 420, top: 550 },
        ]}
      />
    </div>
  );
}

/** Three signalling cards all offscreen past the same (right) edge — shows the
 * anti-overlap stacking `stackPills` produces (each pill nudged `stackGap`
 * below the last), with a mixed bell/live priority ordering. */
export function StackedOnOneEdge() {
  return (
    <div className="board" style={frame}>
      <OffscreenHints
        pills={[
          { cardId: "s1", signal: "bell", label: "agent-1 · 09:41", edge: "right", arrow: "→", left: 700, top: 90 },
          { cardId: "s2", signal: "live", label: "npm run dev", edge: "right", arrow: "→", left: 700, top: 132 },
          { cardId: "s3", signal: "live", label: "README.md", edge: "right", arrow: "→", left: 700, top: 174 },
        ]}
      />
    </div>
  );
}
