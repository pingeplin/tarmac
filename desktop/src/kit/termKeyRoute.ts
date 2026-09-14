// Who handles a key event on a terminal card's xterm textarea — the decision
// behind TerminalCard's `attachCustomKeyEventHandler`, which stays wiring (it
// returns `route(...) === "xterm"`). xterm's handler is binary; the non-xterm
// routes name who takes the key once xterm stands aside:
//   - "beforeinput": plain printable chars reach the PTY through TerminalCard's
//     `beforeinput` interceptor, so macOS CJK IMEs in alphanumeric mode (which
//     commit every ASCII key as `insertText`) and plain typing share one path.
//   - "browser": ⌘V, so WebKit runs the Edit menu's Paste — like Ghostty, the
//     terminal owns paste. Under a kitty keyboard program (Claude Code pushes
//     flags 5) xterm would encode it as ESC[118;9u and preventDefault the
//     paste; in legacy mode xterm emits nothing for it anyway.
//   - "xterm": xterm's own keydown evaluation — ⌃/⌥ chords (macOptionIsMeta:
//     ⌥O must emit ESC o), named keys, compositions, and everything while a
//     kitty keyboard program owns the encoding. Other ⌘ chords stay too: kitty
//     programs bind them (Claude Code's fullscreen selection copy is `cmd+c`),
//     and legacy ⌘A is xterm's select-all.

export type TermKeyRoute = "xterm" | "beforeinput" | "browser";

export interface TermKeyRouteInput {
  type: string;
  key: string;
  composing: boolean;
  meta: boolean;
  alt: boolean;
  ctrl: boolean;
  kittyActive: boolean;
}

export function route(input: TermKeyRouteInput): TermKeyRoute {
  if (input.type !== "keydown" || input.composing) return "xterm";
  if (input.meta && !input.ctrl && !input.alt && input.key.toLowerCase() === "v") return "browser";
  if (input.ctrl || input.meta || input.alt) return "xterm";
  if (input.kittyActive || input.key.length !== 1) return "xterm";
  return "beforeinput";
}
