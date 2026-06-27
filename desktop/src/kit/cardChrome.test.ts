import { describe, it, expect } from "vitest";
import { borderRole, showsHandles, cardChromeState, cardHandles, type BorderRole } from "./cardChrome";

// Port of CardChromeTests.swift (2606.0006): the active-card chrome rule with
// `fresh` dropped from the border. The teal ring + handles mark an active card
// (focused OR selected); `prime` and `fresh` are border-inert; dead/detached is
// the one divergence (muted border yet handles for resize).
describe("CardChrome", () => {
  // S1: a fresh-but-not-active card draws the plain line and shows no handles.
  it("fresh-not-active is plain, no handles", () => {
    const s = cardChromeState({ fresh: true });
    expect(borderRole(s)).toBe("plain");
    expect(showsHandles(s)).toBe(false);
  });

  // S2: a single-clicked card (focused) shows the teal ring AND handles.
  it("focused is the active ring with handles", () => {
    const s = cardChromeState({ focused: true });
    expect(borderRole(s)).toBe("focus");
    expect(showsHandles(s)).toBe(true);
  });

  // S3: an active card outranks fresh — fresh is inert on the border.
  it("active outranks fresh", () => {
    const s = cardChromeState({ fresh: true, focused: true });
    expect(borderRole(s)).toBe("focus");
    expect(showsHandles(s)).toBe(true);
  });

  // S4: a dead card resized via header grab — muted border yet handles present.
  it("dead + selected is muted but shows handles", () => {
    const s = cardChromeState({ dead: true, selected: true });
    expect(borderRole(s)).toBe("muted");
    expect(showsHandles(s)).toBe(true);
  });

  // S5: exhaustive over all 64 states. Expected sides are derived independently
  // from the inputs (never read back from borderRole), so the test cannot pass
  // by mirroring the implementation.
  it("invariant exhaustive over all 64 states", () => {
    for (let mask = 0; mask < 64; mask++) {
      const s = cardChromeState({
        dead: (mask & 0b000001) !== 0,
        detached: (mask & 0b000010) !== 0,
        fresh: (mask & 0b000100) !== 0,
        prime: (mask & 0b001000) !== 0,
        focused: (mask & 0b010000) !== 0,
        selected: (mask & 0b100000) !== 0,
      });

      // (a) the focus ring coincides with an active, non-dead/detached card.
      const expectFocusRing = (s.focused || s.selected) && !s.dead && !s.detached;
      expect(borderRole(s) === "focus").toBe(expectFocusRing);

      // (b) role coverage — expected computed from inputs.
      const expectedRole: BorderRole =
        s.dead || s.detached ? "muted" : s.focused || s.selected ? "focus" : "plain";
      expect(borderRole(s)).toBe(expectedRole);

      // (c) prime and fresh are border-inert: off vs on changes neither output.
      for (const field of ["prime", "fresh"] as const) {
        const off = { ...s, [field]: false };
        const on = { ...s, [field]: true };
        expect(borderRole(off)).toBe(borderRole(on));
        expect(showsHandles(off)).toBe(showsHandles(on));
      }
    }
  });

  // Retained regression guards.
  it("selected looks like focused", () => {
    const s = cardChromeState({ selected: true });
    expect(borderRole(s)).toBe("focus");
    expect(showsHandles(s)).toBe(true);
  });

  it("prime + focused is focus (prime never overrides)", () => {
    const s = cardChromeState({ prime: true, focused: true });
    expect(borderRole(s)).toBe("focus");
    expect(showsHandles(s)).toBe(true);
  });

  it("prime-but-not-active is plain, no handles", () => {
    const s = cardChromeState({ prime: true });
    expect(borderRole(s)).toBe("plain");
    expect(showsHandles(s)).toBe(false);
  });

  it("idle card is plain, no handles", () => {
    const s = cardChromeState();
    expect(borderRole(s)).toBe("plain");
    expect(showsHandles(s)).toBe(false);
  });

  it("detached + selected is muted but shows handles", () => {
    const s = cardChromeState({ detached: true, selected: true });
    expect(borderRole(s)).toBe("muted");
    expect(showsHandles(s)).toBe(true);
  });
});

// S10 (ring half): idle card never gets the focus ring.
describe("borderRole — idle card", () => {
  it("idle card (focused=false, selected=false) gets plain role, not focus", () => {
    expect(borderRole(cardChromeState())).toBe("plain");
  });
});

// S11 / S14: cardHandles returns the correct ordered set of 8 (or 7) handle ids.
describe("cardHandles", () => {
  it("without close: returns all 8 handles including tr", () => {
    const handles = cardHandles(false);
    expect(handles).toHaveLength(8);
    expect(handles).toContain("tl");
    expect(handles).toContain("t");
    expect(handles).toContain("tr");
    expect(handles).toContain("r");
    expect(handles).toContain("br");
    expect(handles).toContain("b");
    expect(handles).toContain("bl");
    expect(handles).toContain("l");
  });

  it("with close: returns 7 handles, tr omitted", () => {
    const handles = cardHandles(true);
    expect(handles).toHaveLength(7);
    expect(handles).not.toContain("tr");
    // all others present
    expect(handles).toContain("tl");
    expect(handles).toContain("t");
    expect(handles).toContain("r");
    expect(handles).toContain("br");
    expect(handles).toContain("b");
    expect(handles).toContain("bl");
    expect(handles).toContain("l");
  });
});
