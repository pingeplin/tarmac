import { describe, it, expect } from "vitest";
import { devTypePlan, devTypeSummary, type TypeStep } from "./devTypePlan";
import { devKeyPlan } from "./devKeyPlan";
import { xtermHandlesKey } from "./termKeyRoute";

const inert = (char: string) => ({
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
});

const kinds = (steps: TypeStep[]) => steps.map((s) => s.kind);
const keyEvents = (step: TypeStep) => {
  if (step.kind !== "key") throw new Error(`expected a key step, got ${step.kind}`);
  return step.events;
};

describe("S19 — a printable is bracketed by an INERT keydown/keyup", () => {
  const plan = devTypePlan("ab", 0);

  it("plans one insert per character, bracketed, with no keypress", () => {
    expect(plan.mode).toBe("insert");
    expect(kinds(plan.steps)).toEqual(["insert", "insert"]);
    expect(plan.steps[0]).toEqual({
      kind: "insert",
      index: 0,
      char: "a",
      keydown: { type: "keydown", ...inert("a") },
      keyup: { type: "keyup", ...inert("a") },
    });
    expect(plan.steps[1]).toMatchObject({ index: 1, char: "b", keydown: { key: "b" } });
  });

  it("is inert BY THE REAL PREDICATE, which is the anti-vacuity mechanism", () => {
    // A bracket xterm would own can deliver the character itself, and D4/D5/Q2
    // would then all pass for the wrong reason. Import the predicate rather than
    // restate its rule, so a change to it fails here.
    // The KEYDOWN is the one that matters: it is the only half that can deliver a
    // character (xterm's `_keyPress` is the other, and the bracket plans none).
    // xtermHandlesKey returns true for a keyup by construction — xterm's `_keyUp`
    // only tracks composition and alt state — so asserting it there would pin the
    // predicate's early return, not this bracket.
    for (const step of plan.steps) {
      if (step.kind !== "insert") throw new Error("unreachable");
      const d = step.keydown;
      expect(
        xtermHandlesKey({
          type: d.type,
          key: d.key,
          composing: false,
          meta: d.metaKey,
          alt: d.altKey,
          ctrl: d.ctrlKey,
          kittyFlags: 0,
          hasSelection: false,
        }),
      ).toBe(false);
    }
  });
});

describe("S77 — kitty flag 8 switches the whole delivery path", () => {
  it("keeps the insert path under flags 0 and 5", () => {
    for (const flags of [0, 5]) {
      const plan = devTypePlan("a", flags);
      expect(plan.mode).toBe("insert");
      expect(kinds(plan.steps)).toEqual(["insert"]);
    }
  });

  it("plans a plain key event and NO insertText under flag 8", () => {
    // Under flag 8 xtermHandlesKey returns true for any key, so xterm owns the
    // bracket keydown and encodes the character as CSI u — while execCommand
    // would ALSO fire beforeinput and deliver it a second time. Every character
    // would arrive twice. This is what real typing does in that mode.
    const plan = devTypePlan("a", 8);
    expect(plan.mode).toBe("key");
    expect(kinds(plan.steps)).toEqual(["key"]);
    const [down, up] = keyEvents(plan.steps[0]);
    expect(down).toMatchObject({ type: "keydown", key: "a", code: "KeyA", keyCode: 65, which: 65 });
    expect(up.type).toBe("keyup");
    expect(
      xtermHandlesKey({
        type: "keydown",
        key: down.key,
        composing: false,
        meta: false,
        alt: false,
        ctrl: false,
        kittyFlags: 8,
        hasSelection: false,
      }),
    ).toBe(true);
  });

  it("switches on flag 8 wherever it appears in the mask", () => {
    expect(devTypePlan("a", 13).mode).toBe("key");
  });
});

describe("S20/S21/S22 — control characters become key events, not inserts", () => {
  it('"\\n" is the enter plan and nothing else', () => {
    const plan = devTypePlan("\n", 0);
    expect(kinds(plan.steps)).toEqual(["key"]);
    // Literally the S9 plan, imported rather than restated, so the two cannot drift.
    const enter = devKeyPlan("enter");
    if (enter.kind !== "key") throw new Error("unreachable");
    expect(keyEvents(plan.steps[0])).toEqual(enter.events);
  });

  it('"\\t" is the tab plan', () => {
    const plan = devTypePlan("\t", 0);
    expect(kinds(plan.steps)).toEqual(["key"]);
    expect(keyEvents(plan.steps[0])[0]).toMatchObject({ key: "Tab", keyCode: 9 });
  });

  it('"\\x03" is the ctrl+c plan', () => {
    const plan = devTypePlan("\x03", 0);
    expect(kinds(plan.steps)).toEqual(["key"]);
    const ctrlC = devKeyPlan("ctrl+c");
    if (ctrlC.kind !== "key") throw new Error("unreachable");
    expect(keyEvents(plan.steps[0])).toEqual(ctrlC.events);
    // The same rule covers the rest of the C0 range, which is why \x03 is not a
    // hand-written special case: an unmapped control character would otherwise be
    // handed to execCommand, which cannot type one.
    expect(keyEvents(devTypePlan("\x04", 0).steps[0])[0]).toMatchObject({
      key: "d",
      ctrlKey: true,
      keyCode: 68,
    });
    expect(keyEvents(devTypePlan("\x1b", 0).steps[0])[0]).toMatchObject({ key: "Escape" });
  });
});

describe("S23 — a mixed string keeps its order", () => {
  it('"a\\nb" is exactly insert, Enter, insert', () => {
    const plan = devTypePlan("a\nb", 0);
    expect(kinds(plan.steps)).toEqual(["insert", "key", "insert"]);
    expect(plan.steps.map((s) => s.index)).toEqual([0, 1, 2]);
  });
});

describe("S24 — a non-ASCII printable has no keyCode to report", () => {
  it("inserts the character and brackets it with keyCode 0", () => {
    const plan = devTypePlan("中", 0);
    expect(plan.steps[0]).toEqual({
      kind: "insert",
      index: 0,
      char: "中",
      keydown: { type: "keydown", ...inert("中") },
      keyup: { type: "keyup", ...inert("中") },
    });
    // keyCode 0 also keeps it clear of kit/imeGuard's 229 composition sentinel,
    // which a CJK character is otherwise the most likely thing to be confused with.
    expect(plan.steps[0]).toMatchObject({ keydown: { keyCode: 0 } });
  });
});

describe("S71 — the reply body is built from what the driver observed", () => {
  const plan = devTypePlan("a\nb", 0);

  it("counts the key step in chars but neither inserts nor drops it", () => {
    expect(devTypeSummary(plan, [true, true])).toEqual({
      chars: 3,
      inserted: 2,
      dropped: [],
      mode: "insert",
    });
  });

  it("reports a dropped character by its index in the REQUESTED string", () => {
    // D4's `dropped == []` assertion is only as strong as this: a summariser that
    // hard-coded an empty list would make #162's headline scenario unfalsifiable.
    expect(devTypeSummary(plan, [true, false])).toEqual({
      chars: 3,
      inserted: 1,
      dropped: [{ index: 2, char: "b" }],
      mode: "insert",
    });
  });

  it("reports no inserts at all under flag 8", () => {
    expect(devTypeSummary(devTypePlan("a\nb", 8), [])).toEqual({
      chars: 3,
      inserted: 0,
      dropped: [],
      mode: "key",
    });
  });
});

describe("empty text is a no-op the app still answers", () => {
  it("plans nothing and summarises to zeroes", () => {
    const plan = devTypePlan("", 0);
    expect(plan.steps).toEqual([]);
    expect(devTypeSummary(plan, [])).toEqual({ chars: 0, inserted: 0, dropped: [], mode: "insert" });
  });
});
