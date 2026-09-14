// How a terminal card's mouse selection coexists with a program that tracks
// the mouse. TerminalCard applies these on every mousedown/mousemove, since the
// program can toggle tracking at any time.
//   - mouseSelectOptions: ⌥-drag forces a selection only while tracking is on.
//     On macOS `macOptionClickForcesSelection` also turns off ⌥-drag column
//     select, which shells keep. It hands a quick ⌥-click to xterm's
//     `altClickMovesCursor`, whose arrow keys would drive the program (Claude
//     Code's ↑ walks history), so cursor moves stay shell-only.
//   - swallowsHover: xterm clears its selection on any user input, and every
//     hover report counts. Only any-event tracking (`?1003h`) reports hover, so
//     under it a buttonless move over the terminal is kept from xterm while a
//     selection is shown. Cost, under any-event tracking only: no hover reports
//     or link underline while a selection is shown; a plain click dismisses it
//     and reports resume.

import type { IModes } from "@xterm/xterm";

type MouseTrackingMode = IModes["mouseTrackingMode"];

export interface MouseSelectOptions {
  macOptionClickForcesSelection: boolean;
  altClickMovesCursor: boolean;
}

export function mouseSelectOptions(mode: MouseTrackingMode): MouseSelectOptions {
  const tracking = mode !== "none";
  return { macOptionClickForcesSelection: tracking, altClickMovesCursor: !tracking };
}

export function swallowsHover(input: { mode: MouseTrackingMode; buttons: number; hasSelection: boolean }): boolean {
  return input.mode === "any" && input.buttons === 0 && input.hasSelection;
}
