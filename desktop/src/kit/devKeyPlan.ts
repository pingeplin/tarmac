// What `tarmac dev key <card> <combo>` dispatches (spec 2609.0015, issue #166).
//
// The grammar is a CLOSED set on purpose: a scenario that typos a combo must fail
// loudly rather than silently send a neighbouring one. Two refusals carry a
// reason, because both name a key that a dispatched event genuinely cannot
// deliver:
//   - cmd/meta depend on WebKit's native Edit-menu action, which only a trusted
//     event triggers.
//   - a bare letter or digit is refused because kit/termKeyRoute's xtermHandlesKey
//     returns FALSE for it: xterm stands aside without preventDefault and the only
//     remaining path to the PTY is the `beforeinput` interceptor, which a
//     synthetic key event never fires. `key <term> "a"` would be a silent no-op.
//     A letter or digit is fine as the base of a ctrl/alt chord, where xterm owns
//     and encodes it — which is what `type` uses for \x03 and friends.
//
// No plan contains a `keypress`. Measured on the stage-2 entry pre-check (#174):
// xterm owns every key in this grammar and cancels the keydown, so the app never
// sees one — not even for Enter, which WebKit does fire one for on a bare
// textarea.

export interface KeyDescriptor {
  type: "keydown" | "keyup";
  key: string;
  code: string;
  keyCode: number;
  which: number;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  metaKey: boolean;
  bubbles: true;
  cancelable: true;
}

export interface MouseDescriptor {
  type: "mousemove" | "contextmenu";
  clientX: number;
  clientY: number;
  bubbles: true;
  cancelable: true;
  button?: number;
  buttons?: number;
}

export type KeyPlan =
  | { kind: "key"; events: KeyDescriptor[] }
  /** Not a keyboard plan: the driver resolves a cell point (kit/devCellPoint) and
   *  calls `contextMenuPlan`. Kept out of `key` so S13's flat "no keypress, ever"
   *  rule is about keyboard plans and nothing else. */
  | { kind: "contextmenu" }
  | { kind: "error"; error: "unsupported_combo" | "bad_combo"; message: string };

const NAMED: Record<string, { key: string; code: string; keyCode: number }> = {
  enter: { key: "Enter", code: "Enter", keyCode: 13 },
  tab: { key: "Tab", code: "Tab", keyCode: 9 },
  escape: { key: "Escape", code: "Escape", keyCode: 27 },
  backspace: { key: "Backspace", code: "Backspace", keyCode: 8 },
  up: { key: "ArrowUp", code: "ArrowUp", keyCode: 38 },
  down: { key: "ArrowDown", code: "ArrowDown", keyCode: 40 },
  left: { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 },
  right: { key: "ArrowRight", code: "ArrowRight", keyCode: 39 },
};

const MODIFIERS = ["ctrl", "shift", "alt"];
const NATIVE_MODIFIERS = ["cmd", "meta"];
/** Exported so routing spells the verb the same way the grammar does; a rename
 *  that reached only one of them would compile and silently route to the
 *  textarea, where a right-click yields a Caret instead of a Range. */
export const CONTEXT_MENU = "contextmenu";

const bad = (message: string): KeyPlan => ({ kind: "error", error: "bad_combo", message });
const unsupported = (message: string): KeyPlan => ({
  kind: "error",
  error: "unsupported_combo",
  message,
});

export function devKeyPlan(combo: string): KeyPlan {
  const parts = combo.split("+");
  const base = parts[parts.length - 1];
  const mods = parts.slice(0, -1);

  if (mods.some((m) => NATIVE_MODIFIERS.includes(m))) {
    return unsupported(
      "cmd/meta chords reach the PTY through WebKit's native Edit menu action, which an untrusted dispatched event never triggers",
    );
  }
  if (mods.some((m) => !MODIFIERS.includes(m))) {
    return bad(`unknown modifier in \`${combo}\`; the set is ctrl, shift, alt (lowercase)`);
  }
  if (new Set(mods).size !== mods.length) return bad(`repeated modifier in \`${combo}\``);

  const flags = {
    ctrlKey: mods.includes("ctrl"),
    shiftKey: mods.includes("shift"),
    altKey: mods.includes("alt"),
    metaKey: false,
  };

  if (base === CONTEXT_MENU) {
    return mods.length === 0
      ? { kind: "contextmenu" }
      : bad("`contextmenu` takes no modifiers");
  }

  const named = NAMED[base];
  if (named) return { kind: "key", events: pair(named, flags) };

  if (/^[a-z0-9]$/.test(base)) {
    if (!flags.ctrlKey && !flags.altKey) {
      return unsupported(
        `\`${combo}\` is a printable character: xterm stands aside for it and a dispatched key event reaches nothing — use \`tarmac dev type\` instead`,
      );
    }
    const { code, keyCode } = physicalKey(base);
    return {
      kind: "key",
      events: pair(
        {
          // WebKit uppercases a letter under shift. A digit's shifted symbol is
          // layout-dependent, so the digit itself is reported rather than guessed.
          key: flags.shiftKey ? base.toUpperCase() : base,
          code,
          keyCode,
        },
        flags,
      ),
    };
  }

  return bad(
    `\`${combo}\` is not in the combo grammar: a named key (${Object.keys(NAMED).join(", ")}), a lowercase letter or digit with ctrl or alt, or \`contextmenu\``,
  );
}

/** The mouse pair for `key <card> contextmenu`, at a point from kit/devCellPoint.
 *  The leading mousemove is load-bearing: TerminalCard patches
 *  getBoundingClientRect anchored on lastMouseX/lastMouseY, which it tracks from
 *  real mousedown/mousemove only — never from contextmenu. Without it xterm's
 *  getCoords reads a stale anchor and resolves a cell far from this one. */
export function contextMenuPlan(point: { x: number; y: number }): MouseDescriptor[] {
  const at = { clientX: point.x, clientY: point.y, bubbles: true, cancelable: true } as const;
  return [
    { type: "mousemove", ...at },
    { type: "contextmenu", ...at, button: 2, buttons: 2 },
  ];
}

/** The keydown/keyup pair every plan is made of. Exported so `devTypePlan` builds
 *  its brackets from the same ten fields rather than a second hand-written copy. */
export function pair(
  key: { key: string; code: string; keyCode: number },
  flags: { ctrlKey: boolean; shiftKey: boolean; altKey: boolean; metaKey: boolean },
): KeyDescriptor[] {
  const shared = { ...key, which: key.keyCode, ...flags, bubbles: true, cancelable: true } as const;
  return [
    { type: "keydown", ...shared },
    { type: "keyup", ...shared },
  ];
}

// ── The US-layout physical key behind an ASCII printable ───────────────────────
//
// Measured from real key chords in WebKit (#174 pre-check 6), and shared with
// `devTypePlan` because both need the same answer for different reasons: a combo
// like `ctrl+c` needs the `code`/`keyCode` a real `c` press carries, and `type`
// under kitty flag 8 needs them because xterm encodes CSI u from `keyCode`, which
// kitty defines as the UNSHIFTED key — so `!` must carry Digit1/49, not its own
// code point 33, or a flag-8 program receives a key nobody pressed. The harness
// compares every ASCII printable against a real chord: 36/36 byte-identical.
//
// One documented difference: a real shifted press also reports the Shift key
// itself (ESC[57441;2u) before the character; no modifier keydown is planned, so
// a flag-8 program that acts on Shift's own press sees one fewer event.
//
// A synthetic event has no layout, so US is the only table there can be; a
// non-ASCII character reports nothing at all, the same rule as S24.

const SHIFTED_DIGITS = ")!@#$%^&*(";
const PUNCTUATION: Record<string, { code: string; keyCode: number; shift: boolean }> = {
  " ": { code: "Space", keyCode: 32, shift: false },
  ";": { code: "Semicolon", keyCode: 186, shift: false },
  ":": { code: "Semicolon", keyCode: 186, shift: true },
  "=": { code: "Equal", keyCode: 187, shift: false },
  "+": { code: "Equal", keyCode: 187, shift: true },
  ",": { code: "Comma", keyCode: 188, shift: false },
  "<": { code: "Comma", keyCode: 188, shift: true },
  "-": { code: "Minus", keyCode: 189, shift: false },
  _: { code: "Minus", keyCode: 189, shift: true },
  ".": { code: "Period", keyCode: 190, shift: false },
  ">": { code: "Period", keyCode: 190, shift: true },
  "/": { code: "Slash", keyCode: 191, shift: false },
  "?": { code: "Slash", keyCode: 191, shift: true },
  "`": { code: "Backquote", keyCode: 192, shift: false },
  "~": { code: "Backquote", keyCode: 192, shift: true },
  "[": { code: "BracketLeft", keyCode: 219, shift: false },
  "{": { code: "BracketLeft", keyCode: 219, shift: true },
  "\\": { code: "Backslash", keyCode: 220, shift: false },
  "|": { code: "Backslash", keyCode: 220, shift: true },
  "]": { code: "BracketRight", keyCode: 221, shift: false },
  "}": { code: "BracketRight", keyCode: 221, shift: true },
  "'": { code: "Quote", keyCode: 222, shift: false },
  '"': { code: "Quote", keyCode: 222, shift: true },
};

export function physicalKey(char: string): { code: string; keyCode: number; shift: boolean } {
  if (/^[a-zA-Z]$/.test(char)) {
    const upper = char.toUpperCase();
    return { code: `Key${upper}`, keyCode: upper.charCodeAt(0), shift: char === upper };
  }
  if (/^[0-9]$/.test(char)) {
    return { code: `Digit${char}`, keyCode: char.charCodeAt(0), shift: false };
  }
  const digit = SHIFTED_DIGITS.indexOf(char);
  if (digit >= 0) return { code: `Digit${digit}`, keyCode: 48 + digit, shift: true };
  return PUNCTUATION[char] ?? { code: "", keyCode: 0, shift: false };
}
