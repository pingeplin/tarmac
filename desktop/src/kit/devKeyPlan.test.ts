import { describe, it, expect } from "vitest";
import { devKeyPlan, contextMenuPlan, type KeyDescriptor } from "./devKeyPlan";
import { xtermHandlesKey } from "./termKeyRoute";

const keys = (combo: string): KeyDescriptor[] => {
  const plan = devKeyPlan(combo);
  if (plan.kind !== "key") throw new Error(`${combo} did not plan keys: ${JSON.stringify(plan)}`);
  return plan.events;
};

describe("S9 — enter", () => {
  it("plans keydown and keyup, and NO keypress", () => {
    // Measured on the stage-2 entry pre-check (#174): WebKit fires a keypress for
    // Enter on a bare textarea, but the app never sees one — xtermHandlesKey
    // returns true for Enter, xterm cancels the keydown, and no keypress follows.
    expect(keys("enter").map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of keys("enter")) {
      expect(e).toMatchObject({ key: "Enter", code: "Enter", keyCode: 13, which: 13 });
    }
  });
});

describe("S10 — ctrl+c", () => {
  it("plans keydown and keyup, and NO keypress", () => {
    // A plan that emitted keypress here would feed #156's dedupe a sequence
    // WebKit does not produce, making any future regression test of it lie.
    expect(keys("ctrl+c").map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of keys("ctrl+c")) {
      expect(e).toMatchObject({ key: "c", ctrlKey: true, keyCode: 67 });
    }
  });
});

describe("S11 — shift+enter", () => {
  it("sets shiftKey on both events and still plans no keypress", () => {
    const events = keys("shift+enter");
    expect(events.map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of events) expect(e).toMatchObject({ key: "Enter", shiftKey: true, keyCode: 13 });
  });
});

describe("S12 — escape", () => {
  it("plans keydown and keyup with keyCode 27, no keypress", () => {
    expect(keys("escape").map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of keys("escape")) expect(e).toMatchObject({ key: "Escape", keyCode: 27 });
  });
});

describe("S12b — alt+left carries `code`, which is the only thing that routes it", () => {
  it("plans ArrowLeft with code set and alt only", () => {
    // App.tsx's window keydown handler routes #21's Ghostty-parity rows through
    // kit/termKeyBinding.ts, which matches on `code` alone. A plan with an empty
    // `code` would drive every named key except those rows, unnoticed.
    const events = keys("alt+left");
    expect(events.map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of events) {
      expect(e).toMatchObject({
        key: "ArrowLeft",
        code: "ArrowLeft",
        altKey: true,
        ctrlKey: false,
        shiftKey: false,
        metaKey: false,
        keyCode: 37,
      });
    }
  });
});

describe("S12c — alt+tab plans normally", () => {
  it("parses and plans like any other combo", () => {
    // It cycles the prime terminal (App.tsx catches alt-only Tab at the window
    // capture phase), so it never reaches the PTY and it MOVES FOCUS — breaking
    // the not_focused precondition for every later verb in the same scenario.
    // That is documented in the `key` docs, not enforced here.
    const events = keys("alt+tab");
    expect(events.map((e) => e.type)).toEqual(["keydown", "keyup"]);
    for (const e of events) expect(e).toMatchObject({ key: "Tab", code: "Tab", altKey: true });
  });
});

describe("S13 — the whole accepted set", () => {
  const NAMED = ["enter", "tab", "escape", "backspace", "up", "down", "left", "right"];
  const MODIFIERS = ["", "ctrl+", "shift+", "alt+", "ctrl+shift+", "ctrl+alt+", "alt+shift+"];
  const rows: string[] = [];
  for (const key of NAMED) for (const m of MODIFIERS) rows.push(m + key);
  // A letter and a digit are accepted ONLY as the base of a ctrl or alt chord.
  for (const base of ["c", "7"]) {
    for (const m of ["ctrl+", "alt+", "ctrl+shift+", "alt+shift+", "ctrl+alt+"]) {
      rows.push(m + base);
    }
  }

  it.each(rows)("%s plans a well-formed, deliverable pair", (combo) => {
    const events = keys(combo);
    // Flat rule: no keyboard plan contains a keypress. The closed grammar makes it
    // true — xterm owns every named key and every ctrl/alt chord and cancels the
    // keydown, and the one family that would fire a keypress is refused by S14b.
    expect(events.map((e) => e.type)).toEqual(["keydown", "keyup"]);
    const named = new Set(combo.split("+").slice(0, -1));
    for (const e of events) {
      // React listens at the root and xterm's evaluator reads keyCode, so a
      // descriptor missing either is inert in the app while still "passing" a
      // shallower test.
      expect(e.bubbles).toBe(true);
      expect(e.cancelable).toBe(true);
      expect(e.keyCode).toBe(e.which);
      expect(e.keyCode).toBeGreaterThan(0);
      expect(e.key).not.toBe("");
      expect(e.code).not.toBe("");
      expect(e.ctrlKey).toBe(named.has("ctrl"));
      expect(e.shiftKey).toBe(named.has("shift"));
      expect(e.altKey).toBe(named.has("alt"));
      expect(e.metaKey).toBe(false);
    }
  });

  it.each([
    ["enter", "Enter", "Enter", 13],
    ["tab", "Tab", "Tab", 9],
    ["escape", "Escape", "Escape", 27],
    ["backspace", "Backspace", "Backspace", 8],
    ["up", "ArrowUp", "ArrowUp", 38],
    ["down", "ArrowDown", "ArrowDown", 40],
    ["left", "ArrowLeft", "ArrowLeft", 37],
    ["right", "ArrowRight", "ArrowRight", 39],
  ] as const)("%s is exactly %s / %s / %i", (combo, key, code, keyCode) => {
    // The values, not just the shape. Without this row `up` could carry
    // ArrowDown's keyCode and send the wrong key to the PTY with the whole suite
    // green — the table above only asserts that `keyCode` is non-zero and equals
    // `which`.
    for (const e of keys(combo)) expect(e).toMatchObject({ key, code, keyCode, which: keyCode });
  });

  it("uppercases a shifted letter base, and leaves a shifted digit alone", () => {
    // WebKit uppercases a letter under shift, so a plan that did not would carry a
    // `key` no real press produces. A digit's shifted face is layout-dependent
    // (`shift+7` is `&` on US, `/` on DE), so the driver reports the digit rather
    // than guessing — the same refusal to invent as S24's `keyCode: 0`.
    expect(keys("ctrl+shift+c")[0]).toMatchObject({ key: "C", code: "KeyC", keyCode: 67 });
    expect(keys("ctrl+c")[0]).toMatchObject({ key: "c", code: "KeyC", keyCode: 67 });
    expect(keys("ctrl+shift+7")[0]).toMatchObject({ key: "7", code: "Digit7", keyCode: 55 });
  });

  it.each(rows)("%s is a combo xterm actually delivers", (combo) => {
    // The anti-vacuity half: every accepted combo must be one xterm OWNS, or the
    // key verb is a silent no-op for it. The real predicate, not a restatement.
    const [down] = keys(combo);
    expect(
      xtermHandlesKey({
        type: down.type,
        key: down.key,
        composing: false,
        meta: down.metaKey,
        alt: down.altKey,
        ctrl: down.ctrlKey,
        kittyFlags: 0,
        hasSelection: false,
      }),
    ).toBe(true);
  });
});

describe("S14b — a bare printable is refused, with `type` as the remedy", () => {
  it.each(["a", "7", "shift+a"])("%s is unsupported_combo with an empty plan", (combo) => {
    const plan = devKeyPlan(combo);
    expect(plan).toMatchObject({ kind: "error", error: "unsupported_combo" });
    if (plan.kind !== "error") throw new Error("unreachable");
    expect(plan.message).toMatch(/type/);
    expect(devKeyPlan(combo)).not.toHaveProperty("events");
  });

  it("is refused because xterm stands aside for that shape, not by taste", () => {
    // Feed the descriptor "a" WOULD have produced to the real predicate. If it
    // ever starts returning true the combo becomes deliverable and this fails,
    // telling you the refusal is now wrong rather than silently enforcing it.
    expect(
      xtermHandlesKey({
        type: "keydown",
        key: "a",
        composing: false,
        meta: false,
        alt: false,
        ctrl: false,
        kittyFlags: 0,
        hasSelection: false,
      }),
    ).toBe(false);
  });
});

describe("S14 — cmd/meta are refused, with the reason", () => {
  it.each(["cmd+c", "meta+v"])("%s names WebKit's Edit-menu action", (combo) => {
    const plan = devKeyPlan(combo);
    expect(plan).toMatchObject({ kind: "error", error: "unsupported_combo" });
    if (plan.kind !== "error") throw new Error("unreachable");
    expect(plan.message).toMatch(/Edit menu/i);
  });
});

describe("S15 — malformed combos are bad_combo, never a neighbour", () => {
  it.each(["ctrl+", "", "frobnicate", "CTRL+C", "ctrl+shift"])("%s", (combo) => {
    // CTRL+C pins that the grammar is lowercase-only rather than case-folded, so
    // a scenario's typo can never resolve to a neighbouring combo.
    expect(devKeyPlan(combo)).toMatchObject({ kind: "error", error: "bad_combo" });
  });
});

describe("S16 — contextmenu is a mouse plan", () => {
  it("is routed out of the keyboard grammar", () => {
    expect(devKeyPlan("contextmenu")).toEqual({ kind: "contextmenu" });
    // No modifiers: the grammar admits the bare word only.
    expect(devKeyPlan("ctrl+contextmenu")).toMatchObject({ kind: "error", error: "bad_combo" });
  });

  it("leads with a mousemove at the same point, then the contextmenu", () => {
    // The mousemove is load-bearing, not politeness: TerminalCard patches
    // getBoundingClientRect anchored on lastMouseX/lastMouseY, which it tracks
    // from real mousedown/mousemove only — never from contextmenu. Without it
    // xterm's getCoords resolves a cell far from the one S17 computed.
    expect(contextMenuPlan({ x: 120.5, y: 64 })).toEqual([
      { type: "mousemove", clientX: 120.5, clientY: 64, bubbles: true, cancelable: true },
      {
        type: "contextmenu",
        clientX: 120.5,
        clientY: 64,
        bubbles: true,
        cancelable: true,
        button: 2,
        buttons: 2,
      },
    ]);
  });
});
