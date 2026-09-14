// Whether a quick ⌥-click walks the prompt cursor to the clicked cell — xterm's
// `altClickMovesCursor`, which does it by sending arrow keys. TerminalCard sets
// `macOptionClickForcesSelection` so ⌥-drag selects under mouse-tracking apps,
// and that also hands a ⌥-click to this cursor move, where the arrows would
// drive the app instead (Claude Code's ↑ walks history). The program can toggle
// tracking at any time, so TerminalCard asks on every mousedown.

export type MouseTrackingMode = "none" | "x10" | "vt200" | "drag" | "any";

export function altClickMovesCursor(mode: MouseTrackingMode): boolean {
  return mode === "none";
}
