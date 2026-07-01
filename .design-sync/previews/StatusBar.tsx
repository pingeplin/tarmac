// Authored previews for StatusBar — the 27px bottom status bar (port of
// StatusBar.swift, desktop/src/ui/StatusBar.tsx): agent glyph + "tarmac" +
// connection word on the left, card count on the right. Pure render over
// `connected` / `reason` / `cards` — the only real variant axis is the
// connected/detached split (and whether a custom detach `reason` is supplied
// vs. the "detached" fallback) plus the card-count singular/plural text.
//
// `.status-bar` is NOT position:absolute — it's a normal flex child
// (`flex: 0 0 27px; height: 27px`) meant to sit at the bottom of the app's
// flex column, and as a block-level element it already defaults to 100%
// width of its containing block, so it doesn't hit the position:absolute
// sliver/clip gotcha the other board-chrome components do. Still wrapping it
// in a `.board`-shaped box (per the shared convention, wide + exactly as
// short as the real bar) so the story's frame matches how it actually reads
// pinned along the bottom edge of the window.
import { StatusBar } from "tarmac-app";

const frame = { position: "relative" as const, width: 640, height: 27 };

/** The common steady state (matches kit-fixtures.mjs): attached daemon, 5
 * cards on the board. */
export function Connected() {
  return (
    <div className="board" style={frame}>
      <StatusBar connected cards={5} />
    </div>
  );
}

/** Daemon connection dropped with no explicit reason — falls back to the
 * literal "detached" text, amber-colored. */
export function Detached() {
  return (
    <div className="board" style={frame}>
      <StatusBar connected={false} cards={5} />
    </div>
  );
}

/** Detached with a specific reason surfaced (e.g. daemon restarting after a
 * version-mismatch auto-restart) and a singular "1 card" board. */
export function DetachedWithReason() {
  return (
    <div className="board" style={frame}>
      <StatusBar connected={false} reason="daemon restarting…" cards={1} />
    </div>
  );
}
