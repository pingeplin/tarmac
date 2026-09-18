// Whether xterm handles a key event on a terminal card's textarea — the
// decision behind TerminalCard's `attachCustomKeyEventHandler`, which stays
// wiring. `false` makes xterm stand aside without preventDefault, and the key
// takes one of two paths:
//   - plain printable chars reach the PTY through TerminalCard's `beforeinput`
//     interceptor, so macOS CJK IMEs in alphanumeric mode (which commit every
//     ASCII key as `insertText`) and plain typing share one path. xterm stands
//     aside on keypress too, or its `_keyPress` would send the char first. A
//     dead-key keydown without ⌥ (plain, ⇧, ⌃ or ⌘) outside a composition stands
//     aside as well: xterm would otherwise set its dead-key flag, which only its
//     keypress/input paths reset, and swallow the next key it owns (Enter, an
//     arrow, ⌃C).
//   - ⌘V reaches WebKit's Edit menu Paste, and ⌘C its Copy while the terminal
//     has a selection (Ghostty's `performable:` semantics). Under a kitty
//     keyboard program (Claude Code pushes flags 5) xterm would encode them as
//     ESC[118;9u / ESC[99;9u and preventDefault the menu action; in legacy mode
//     xterm emits nothing for them anyway.
// xterm keeps ⌃/⌥ chords (macOptionIsMeta: ⌥O must emit ESC o), named keys,
// compositions, and plain printable chars when a kitty program asks for every
// key as an escape code. Under a kitty program every ⌘ chord on a character key
// stands aside instead, so the native menu's key equivalents decide: xterm would
// otherwise encode ⌘Q as ESC[113;9u and preventDefault it, leaving Quit, Hide,
// Minimize and Select All dead while Claude Code has focus (#171). Plain
// ⌘C without a selection is the one exception, because Claude Code's fullscreen
// selection copy is `cmd+c`. Legacy mode is unchanged: ⌘ chords stay with xterm,
// where ⌘A is its select-all.

export interface TermKeyRouteInput {
  type: string;
  key: string;
  composing: boolean;
  meta: boolean;
  alt: boolean;
  ctrl: boolean;
  kittyFlags: number;
  hasSelection: boolean;
}

// Only this kitty flag turns every plain printable key into CSI u. Under the
// others xterm's encoder emits the raw char for text keys — the bytes the
// beforeinput path sends — but not for numpad keys, which flags 1/2 encode as
// CSI u (codes 57399–57415); beforeinput still sends the raw char there, as
// before #149.
const REPORT_ALL_KEYS_AS_ESCAPE_CODES = 8;

export function xtermHandlesKey(input: TermKeyRouteInput): boolean {
  if ((input.type !== "keydown" && input.type !== "keypress") || input.composing) return true;
  if (input.meta && input.kittyFlags > 0 && input.key.length === 1) {
    return !input.ctrl && !input.alt && input.key.toLowerCase() === "c" && !input.hasSelection;
  }
  if (input.meta && !input.ctrl && !input.alt) {
    const key = input.key.toLowerCase();
    if (key === "v" || (key === "c" && input.hasSelection)) return false;
  }
  if (input.type === "keydown" && input.key === "Dead" && !input.alt) return false;
  if (input.ctrl || input.meta || input.alt) return true;
  return (input.kittyFlags & REPORT_ALL_KEYS_AS_ESCAPE_CODES) !== 0 || input.key.length !== 1;
}
