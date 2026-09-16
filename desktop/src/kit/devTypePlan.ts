// How `tarmac dev type <card> "<text>"` delivers each character (spec 2609.0015,
// issue #166).
//
// Two paths, and which one a character takes is a decision with a cited cost:
//
//  - A PRINTABLE goes through `execCommand("insertText")`, bracketed by an INERT
//    keydown/keyup. Inert is the whole point (Decision 1): the bracket exists so
//    anything watching sees a key happen, and `code: ""` / `keyCode: 0` is what
//    makes kit/termKeyRoute's xtermHandlesKey return FALSE for it — xterm stands
//    aside, and the character reaches the PTY only through TerminalCard's
//    `beforeinput` interceptor. That is the path #162 broke, so it is the path the
//    scenarios must exercise. A bracket xterm would own could deliver the
//    character itself and D4/D5/Q2 would pass without testing anything.
//    The bracket is a marker, not a replica: a real printable does get a
//    `keypress` in the app (#174 pre-check), and this one deliberately omits it —
//    nothing in the app listens for `keypress`, so the event would be inert, while
//    adding it would rest the bracket's one contract on a further row of the
//    predicate.
//
//  - A CONTROL CHARACTER becomes a key plan, because execCommand cannot type one.
//    \n, \r, \t, \x1b and \x7f are the named keys, and \x01–\x1a are the ctrl
//    chords they stand for (\x03 → ctrl+c) — a rule rather than a list, so \x03 is
//    not a special case and no letter chord is missing. \x00 and \x1c–\x1f have no
//    spelling in the `<combo>` grammar (they are ctrl+@ and ctrl+\ ] ^ _), so they
//    fall through to the insert path like any other character. Widening the
//    grammar for them would make `comboEvents` the only caller that can throw.
//
// Under KITTY FLAG 8 the printable path switches to a key event too (S77): xterm
// then owns every key and encodes it as CSI u, so an execCommand on top would fire
// `beforeinput` and deliver the character a SECOND time. That is also what real
// typing does in that mode. Consequence for scenarios: under flag 8 `type` does
// not exercise the beforeinput path at all, so the #162 scenarios are meaningful
// only against a plain shell.

import { devKeyPlan, type KeyDescriptor } from "./devKeyPlan";

export type TypeStep =
  | { kind: "insert"; index: number; char: string; keydown: KeyDescriptor; keyup: KeyDescriptor }
  | { kind: "key"; index: number; char: string; events: KeyDescriptor[] };

export interface TypePlan {
  /** How PRINTABLE characters are delivered. Control characters are key events in
   *  both modes. A terminal-level fact, constant for one request. */
  mode: "insert" | "key";
  steps: TypeStep[];
}

export interface TypeSummary {
  chars: number;
  inserted: number;
  dropped: Array<{ index: number; char: string }>;
  mode: "insert" | "key";
}

/** The one flag that makes xterm claim every plain printable key. */
const REPORT_ALL_KEYS_AS_ESCAPE_CODES = 8;

const NAMED_CONTROL: Record<string, string> = {
  "\n": "enter",
  "\r": "enter",
  "\t": "tab",
  "\x1b": "escape",
  "\x7f": "backspace",
};

export function devTypePlan(text: string, kittyFlags: number): TypePlan {
  const mode = (kittyFlags & REPORT_ALL_KEYS_AS_ESCAPE_CODES) !== 0 ? "key" : "insert";
  const steps: TypeStep[] = [];
  // By code point, so an astral character is one step rather than two broken
  // halves; `index` counts the same way.
  const chars = [...text];
  for (let index = 0; index < chars.length; index++) {
    const char = chars[index];
    const combo = controlCombo(char);
    if (combo) {
      steps.push({ kind: "key", index, char, events: comboEvents(combo) });
    } else if (mode === "key") {
      steps.push({ kind: "key", index, char, events: printableEvents(char) });
    } else {
      steps.push({
        kind: "insert",
        index,
        char,
        keydown: { type: "keydown", ...inert(char) },
        keyup: { type: "keyup", ...inert(char) },
      });
    }
  }
  return { mode, steps };
}

/** `inserted` carries one boolean per INSERT step, in order — what `execCommand`
 *  returned for each. Key steps have no result to report: they are counted in
 *  `chars` and are neither inserted nor dropped. */
export function devTypeSummary(plan: TypePlan, inserted: boolean[]): TypeSummary {
  const dropped: Array<{ index: number; char: string }> = [];
  let ok = 0;
  let nth = 0;
  for (const step of plan.steps) {
    if (step.kind !== "insert") continue;
    if (inserted[nth++]) ok++;
    else dropped.push({ index: step.index, char: step.char });
  }
  return { chars: plan.steps.length, inserted: ok, dropped, mode: plan.mode };
}

function controlCombo(char: string): string | null {
  const named = NAMED_CONTROL[char];
  if (named) return named;
  const code = char.charCodeAt(0);
  // \x01–\x1a are the ctrl chords over a–z; the named ones above already left.
  if (code >= 0x01 && code <= 0x1a) return `ctrl+${String.fromCharCode(0x60 + code)}`;
  return null;
}

function comboEvents(combo: string): KeyDescriptor[] {
  const plan = devKeyPlan(combo);
  // Every combo produced here is generated, not user-supplied, so a refusal would
  // be a bug in the mapping above rather than a bad request.
  if (plan.kind !== "key") throw new Error(`devTypePlan produced an unplannable combo: ${combo}`);
  return plan.events;
}

/** The descriptor a real printable keypress carries. Only reachable under flag 8,
 *  where xterm owns and encodes it — which is why `devKeyPlan` still refuses the
 *  same character as a `key` combo (S14b): there, xterm would stand aside and the
 *  event would reach nothing. */
function printableEvents(char: string): KeyDescriptor[] {
  const { code, keyCode, shift } = physicalKey(char);
  const shared = {
    key: char,
    code,
    keyCode,
    which: keyCode,
    ctrlKey: false,
    shiftKey: shift,
    altKey: false,
    metaKey: false,
    bubbles: true,
    cancelable: true,
  } as const;
  return [
    { type: "keydown", ...shared },
    { type: "keyup", ...shared },
  ];
}

// The US-layout physical key behind each ASCII printable, measured from real key
// chords in WebKit (#174 pre-check 6). This is not cosmetic: kitty's CSI u
// reports the UNSHIFTED key, and xterm derives it from `keyCode` — so `!` must
// carry Digit1/49 with shift, or `type` emits ESC[33;2u where a real press emits
// ESC[49;2u and the program receives a key nobody pressed. The harness compares
// every ASCII printable against a real chord: 36/36 byte-identical.
//
// One documented difference remains. A real shifted press also reports the Shift
// key itself (ESC[57441;2u) before the character; the driver plans no modifier
// keydown, so a flag-8 program that acts on Shift's own press sees one fewer
// event. Left as-is: the character arrives identically, and bracketing every
// shifted character with a Shift press/release would put events on the wire for
// a corner narrower than the one it fixes.
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

function physicalKey(char: string): { code: string; keyCode: number; shift: boolean } {
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

function inert(char: string) {
  return {
    key: char,
    code: "",
    keyCode: 0,
    which: 0,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    metaKey: false,
    bubbles: true,
    cancelable: true,
  } as const;
}
