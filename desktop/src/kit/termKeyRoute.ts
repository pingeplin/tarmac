// Whether xterm handles a key event on a terminal card's textarea — the
// decision behind TerminalCard's `attachCustomKeyEventHandler`, which stays
// wiring. `false` makes xterm stand aside without preventDefault, and the key
// takes one of two paths:
//   - plain printable chars reach the PTY through TerminalCard's `beforeinput`
//     interceptor, so macOS CJK IMEs in alphanumeric mode (which commit every
//     ASCII key as `insertText`) and plain typing share one path.
//   - ⌘V reaches WebKit's Edit menu Paste — like Ghostty, the terminal owns
//     paste. Under a kitty keyboard program (Claude Code pushes flags 5) xterm
//     would encode it as ESC[118;9u and preventDefault the paste; in legacy
//     mode xterm emits nothing for it anyway.
// xterm keeps ⌃/⌥ chords (macOptionIsMeta: ⌥O must emit ESC o), named keys,
// compositions, and everything while a kitty keyboard program owns the
// encoding. Other ⌘ chords stay too: kitty programs bind them (Claude Code's
// fullscreen selection copy is `cmd+c`), and legacy ⌘A is xterm's select-all.

export interface TermKeyRouteInput {
  type: string;
  key: string;
  composing: boolean;
  meta: boolean;
  alt: boolean;
  ctrl: boolean;
  kittyActive: boolean;
}

export function xtermHandlesKey(input: TermKeyRouteInput): boolean {
  if (input.type !== "keydown" || input.composing) return true;
  if (input.meta && !input.ctrl && !input.alt && input.key.toLowerCase() === "v") return false;
  if (input.ctrl || input.meta || input.alt) return true;
  return input.kittyActive || input.key.length !== 1;
}
