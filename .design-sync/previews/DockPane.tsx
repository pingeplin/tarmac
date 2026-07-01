// Authored previews for DockPane — the fixed bottom pane that hosts the docked
// prime terminal (desktop/src/ui/DockPane.tsx). Per its own doc comment,
// `.dock-body` "must have NO React children; the host is appended
// imperatively" (App.tsx reparents the live xterm host node into it via
// `bodyRef` / `DockContext.dockSlot`) — there is no real terminal here, but
// `bodyRef` is exactly the extension point the real app uses to put content
// in, so each story below uses it to append a small plausible placeholder
// (mirroring the terminal-style body used in the CardShell previews in this
// dir) rather than shipping stories with a visibly empty pane, which would
// look broken rather than "no terminal attached yet".
//
// The only prop-driven variant axis DockPane actually has is `label` (App.tsx
// resolves it from the docked TermCardModel's `label`, falling back to
// "shell" when nothing is docked) — swept here at a normal short label, the
// documented "shell" fallback, and a longer descriptive label (a real
// long-running command name) to show the header holds up with more text
// still comfortably inside the `.dock-header .label`/`esc ↩` layout at the
// pane's real full-window width (tried an artificially long single-token
// label to force `.label`'s ellipsis: at this width it instead starves the
// unrelated `.hint` flex item down to wrapping — a real latent 2-line-hint
// gap in chrome.css, but only reachable past any realistic terminal label
// length, so not a sensible canonical story here; noted in learnings instead
// of shipped as a story). `visible` toggles a `display: none` class with
// nothing else to see (same reasoning DocCard.tsx/BoardSwitcher.tsx used to
// skip their analogous no-op-render states), so every story below keeps
// `visible: true`.
//
// GOTCHA (see DocCard.tsx for the full writeup): `.dock-pane` is
// `position: absolute; left/right/bottom: 0; height: 40%` — it's meant to
// hang off the bottom of `.board-stack`. The single-story capture wrapper has
// zero intrinsic height, so `height: 40%` resolves to 0 against it. Wrapping
// in a sized `position: relative` box (standing in for `.board-stack`) gives
// it a real height to take 40% of.
import { DockPane } from "tarmac-app";

const frame = { position: "relative" as const, width: 720, height: 480 };

/** Appends a small terminal-style placeholder into the imperative dock body
 * exactly once (mirrors what App.tsx's real `setDockSlot` reparent produces
 * visually, without a live PTY behind it). */
function fillDockBody(el: HTMLElement | null) {
  if (!el || el.childElementCount > 0) return;
  const pre = document.createElement("pre");
  pre.style.margin = "0";
  pre.style.fontFamily = "monospace";
  pre.style.fontSize = "12px";
  pre.style.color = "var(--text)";
  pre.textContent = "$ npm run build\n\nvite v5 building for production...\n✓ 214 modules transformed.";
  el.appendChild(pre);
}

/** The common steady state: a docked agent terminal ("claude"), esc-to-undock
 * hint visible in the header. */
export function Docked() {
  return (
    <div style={frame}>
      <DockPane visible label="claude" bodyRef={fillDockBody} />
    </div>
  );
}

/** App.tsx's documented fallback label when nothing is actually docked yet
 * (`?? "shell"`). */
export function ShellFallback() {
  return (
    <div style={frame}>
      <DockPane visible label="shell" bodyRef={fillDockBody} />
    </div>
  );
}

/** A long, descriptive terminal label (a real long-running command name) at
 * the same full dock-pane width as the other stories — still complete, no
 * clipping of the `esc ↩` hint. */
export function LongLabel() {
  return (
    <div style={frame}>
      <DockPane
        visible
        label="release-notarize-and-staple-dmg-watcher-for-the-nightly-build-and-cask-bump"
        bodyRef={fillDockBody}
      />
    </div>
  );
}
