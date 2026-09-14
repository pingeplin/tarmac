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
// compositions, and plain printable chars when a kitty program asks for every
// key as an escape code. Other ⌘ chords stay too: kitty programs bind them
// (Claude Code's fullscreen selection copy is `cmd+c`), and legacy ⌘A is xterm's
// select-all.

export interface TermKeyRouteInput {
  type: string;
  key: string;
  composing: boolean;
  meta: boolean;
  alt: boolean;
  ctrl: boolean;
  kittyFlags: number;
}

// Only this kitty flag turns every plain printable key into CSI u. Under the
// others xterm's encoder emits the raw char for text keys — the bytes the
// beforeinput path sends — but not for keypad keys, which flags 1/2 encode as
// CSI 57399+n u; beforeinput still sends the raw digit there, as before #149.
const REPORT_ALL_KEYS_AS_ESCAPE_CODES = 8;

export function xtermHandlesKey(input: TermKeyRouteInput): boolean {
  if (input.type !== "keydown" || input.composing) return true;
  if (input.meta && !input.ctrl && !input.alt && input.key.toLowerCase() === "v") return false;
  if (input.ctrl || input.meta || input.alt) return true;
  return (input.kittyFlags & REPORT_ALL_KEYS_AS_ESCAPE_CODES) !== 0 || input.key.length !== 1;
}
