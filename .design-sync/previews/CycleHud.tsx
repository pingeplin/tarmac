// Authored previews for CycleHud — the transient top-center ⌥Tab terminal-cycling
// readout (desktop/src/ui/CycleHud.tsx). Pure render over a single `hud` prop:
// `null` hides it entirely (returns null — not a useful story), otherwise it's a
// row of pill labels with one marked `active` by index. The only real variant
// axis is the label set (count/length, including the "shell" fallback for an
// empty label) and which index is active.
//
// GOTCHA (see DocCard.tsx for the full writeup): `.cycle-hud` is `position:
// absolute; top: 12px; left: 50%; transform: translateX(-50%)` — centered
// against its containing block. The single-story capture wrapper has zero
// intrinsic height with only an absolutely-positioned child, so `top: 12px`
// still resolves as expected (it's an absolute distance, not a percentage) but
// there's no visible box to see it centered *within*. Wrapping in a plain
// sized `position: relative` board-shaped box (wide + short, matching where
// this HUD actually floats — top-center of the whole app window) gives it a
// real frame to be centered against.
import { CycleHud } from "tarmac-app";

const frame = { position: "relative" as const, width: 720, height: 140 };

/** The common case (matches kit-fixtures.mjs): a dev-shell + a build watcher +
 * an agent shell, cycling has landed on the middle one (npm run dev). */
export function Default() {
  return (
    <div className="board" style={frame}>
      <CycleHud hud={{ labels: ["shell", "npm run dev", "claude"], activeIndex: 1 }} />
    </div>
  );
}

/** Just two terminals — the minimum cycle set (⌥Tab between exactly one pair),
 * landed back on the first. */
export function TwoTerminals() {
  return (
    <div className="board" style={frame}>
      <CycleHud hud={{ labels: ["zsh", "claude"], activeIndex: 0 }} />
    </div>
  );
}

/** A longer row: five terminals including a blank label (a bare shell with no
 * foreground process — falls back to the literal "shell" text per the
 * component's `l || "shell"`), active on the last one. */
export function ManyTerminals() {
  return (
    <div className="board" style={frame}>
      <CycleHud
        hud={{
          labels: ["", "npm run dev", "claude", "tarmacd", "vim docs/protocol.md"],
          activeIndex: 4,
        }}
      />
    </div>
  );
}
