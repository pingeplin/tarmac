// Port of TarmacKit/TermTitle.swift — the pure decision for a terminal card's
// displayed title and its "live" (agent-active) status, from the two title
// sources the app tracks: the OSC title a program emits (OSC 0/1/2) and the
// foreground process name the daemon pushes (`term_proc`).
//
// Precedence (Ghostty semantics): a non-empty OSC title always wins — a program
// that set its own window title is showing what it wants shown. When no OSC
// title is set (never set, or cleared with an empty OSC 2), fall back to the
// daemon's foreground process name, and to the shell basename when even that is
// absent. Swift's `String?` nil and an empty string are treated alike: both are
// a "no title"/"no proc" signal, so `undefined` and `""` behave identically.

/**
 * Whether an OSC title string is an active (displayable) title. Programs clear
 * the window title by emitting an EMPTY OSC 2 — an empty string is a "no title"
 * signal, not a title, so it never wins over the process name.
 */
export function isActive(oscTitle?: string): boolean {
  return oscTitle !== undefined && oscTitle.length > 0;
}

/**
 * The label to display on the card/dock. A non-empty `oscTitle` wins; else the
 * foreground `procName` (when non-empty); else the `shellName`.
 */
export function displayLabel(
  oscTitle: string | undefined,
  procName: string | undefined,
  shellName: string,
): string {
  if (oscTitle !== undefined && oscTitle.length > 0) return oscTitle;
  if (procName !== undefined && procName.length > 0) return procName;
  return shellName;
}

/**
 * Whether the card reads as "live" (agent-active: cyan). A program that set its
 * own OSC title counts as live — it is doing something worth surfacing.
 * Otherwise fall back to the process heuristic: the foreground process is no
 * longer the bare shell.
 */
export function isLive(
  oscTitle: string | undefined,
  procName: string | undefined,
  shellName: string,
): boolean {
  if (isActive(oscTitle)) return true;
  if (procName === undefined || procName.length === 0) return false;
  return procName !== shellName;
}
