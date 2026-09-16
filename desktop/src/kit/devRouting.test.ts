import { describe, it, expect } from "vitest";
import { routeVerb, type RouteContext } from "./devRouting";

const ctx = (over: Partial<RouteContext> = {}): RouteContext => ({
  // Only the ACTIVE board's cards. A hidden board's cards are mounted but
  // display:none, so they are deliberately not addressable.
  cards: [
    { id: "term:t-1", kind: "term", frame: { x: 0, y: 0, w: 1, h: 1 } },
    { id: "doc:/a/b.md", kind: "doc", frame: { x: 0, y: 0, w: 1, h: 1 } },
  ],
  activeElementCard: null,
  ...over,
});

describe("S35 — focus <term> needs both halves", () => {
  it("raises the card, then lets xterm focus its own textarea", () => {
    const route = routeVerb({ t: "focus", card: "t-1" }, ctx());
    expect(route).toEqual({
      kind: "dispatch",
      steps: [
        { target: "card-body", card: "term:t-1", events: ["pointerdown", "pointerup"] },
        { target: "term-element", card: "term:t-1", events: ["mousedown", "mouseup"] },
      ],
    });
  });
});

describe("S36 — focus board", () => {
  it("presses the board viewport itself, with no paired release", () => {
    // Unpaired on purpose: the board binds no pointer-drag gesture (panning is a
    // wheel gesture), so a press leaves nothing mid-flight. The target must be
    // the viewport node itself — Board.tsx gates on e.target identity.
    expect(routeVerb({ t: "focus", card: null }, ctx())).toEqual({
      kind: "dispatch",
      steps: [{ target: "board-viewport", card: null, events: ["pointerdown"] }],
    });
  });
});

describe("S37 — type and key target the textarea, contextmenu does not", () => {
  const focused = ctx({ activeElementCard: "t-1" });

  it("sends text and keys to the hidden textarea", () => {
    for (const verb of [
      { t: "type", card: "t-1", text: "hi" },
      { t: "key", card: "t-1", combo: "ctrl+c" },
    ] as const) {
      const route = routeVerb(verb, focused);
      expect(route).toMatchObject({ kind: "dispatch", steps: [{ target: "term-textarea" }] });
    }
  });

  it("sends a right-click to the xterm element, where xterm listens for it", () => {
    // Routing this to the textarea would produce a Caret, not a Range, and D5
    // would silently degrade into a second copy of D4.
    expect(routeVerb({ t: "key", card: "t-1", combo: "contextmenu" }, focused)).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "term-element" }],
    });
  });
});

describe("S38 — resize targets the bottom-right grip", () => {
  it("routes to .card-handle.br", () => {
    expect(routeVerb({ t: "resize", card: "t-1", w: 800, h: 600 }, ctx())).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-handle-br", card: "term:t-1" }],
    });
  });
});

describe("S39 — an unknown card is refused, with nothing dispatched", () => {
  it("refuses every verb that takes a card", () => {
    for (const verb of [
      { t: "focus", card: "t-9" },
      { t: "type", card: "t-9", text: "x" },
      { t: "key", card: "t-9", combo: "enter" },
      { t: "resize", card: "t-9", w: 1, h: 1 },
    ] as const) {
      expect(routeVerb(verb, ctx())).toEqual({ kind: "error", error: "no_such_card" });
    }
  });

  it("refuses a card on a non-active board the same way", () => {
    // The context carries the active board only, so a hidden board's card is
    // simply absent — routing to one would dispatch events no snapshot could see.
    expect(routeVerb({ t: "focus", card: "t-on-another-board" }, ctx())).toEqual({
      kind: "error",
      error: "no_such_card",
    });
  });
});

describe("S40 — type/key require focus to already be right", () => {
  it("refuses before planning anything when focus is elsewhere", () => {
    for (const verb of [
      { t: "type", card: "t-1", text: "x" },
      { t: "key", card: "t-1", combo: "enter" },
    ] as const) {
      expect(routeVerb(verb, ctx({ activeElementCard: null }))).toEqual({
        kind: "error",
        error: "not_focused",
      });
      expect(routeVerb(verb, ctx({ activeElementCard: "/a/b.md" }))).toEqual({
        kind: "error",
        error: "not_focused",
      });
    }
  });
});

describe("S41 — doc cards have no drivable focus target", () => {
  it("refuses focus, type and key on a doc card", () => {
    for (const verb of [
      { t: "focus", card: "/a/b.md" },
      { t: "type", card: "/a/b.md", text: "x" },
      { t: "key", card: "/a/b.md", combo: "enter" },
    ] as const) {
      expect(routeVerb(verb, ctx())).toEqual({ kind: "error", error: "unsupported_card_kind" });
    }
  });

  it("checks the kind BEFORE the focus precondition", () => {
    // Doc cards render raw HTML, so one can legitimately hold activeElement.
    // Checking focus first would make the error depend on where focus happens
    // to be, which is not a property of the request.
    expect(routeVerb({ t: "type", card: "/a/b.md", text: "x" }, ctx({ activeElementCard: "/a/b.md" })))
      .toEqual({ kind: "error", error: "unsupported_card_kind" });
  });

  it("still allows resizing a doc card, which needs no focus target", () => {
    expect(routeVerb({ t: "resize", card: "/a/b.md", w: 1, h: 1 }, ctx())).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-handle-br", card: "doc:/a/b.md" }],
    });
  });
});

describe("S42 — zoom is not a dispatched event", () => {
  it("routes to the engine's viewport commit, with no element target", () => {
    expect(routeVerb({ t: "zoom", z: 0.5 }, ctx())).toEqual({ kind: "viewport" });
  });
});
