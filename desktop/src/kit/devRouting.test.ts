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
  viewport: { zoom: 1, cx: 0, cy: 0 },
  viewSize: { w: 1000, h: 800 },
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

describe("S76 — the wire speaks bare ids, the app speaks prefixed ones", () => {
  it("resolves a bare id, and refuses the app-internal prefixed form", () => {
    // Tested through routing rather than a standalone inverse, because routing is
    // the only thing that resolves a wire id — and `tarmac dev focus t-1` is what
    // a user types. An implementation that never strips answers `no_such_card`
    // here and passes every other scenario.
    expect(routeVerb({ t: "focus", card: "t-1" }, ctx())).toMatchObject({
      kind: "dispatch",
      steps: [{ card: "term:t-1" }, { card: "term:t-1" }],
    });
    expect(routeVerb({ t: "focus", card: "term:t-1" }, ctx())).toEqual({
      kind: "error",
      error: "no_such_card",
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

describe("S41 — doc cards take focus, but cannot be typed into or keyed", () => {
  it("refuses type and key on a doc card", () => {
    for (const verb of [
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

describe("S8 (2609.0018) — focus on a doc card is a DOM plan per kind", () => {
  const FRAME = { x: 0, y: 0, w: 400, h: 300 };
  const docs = (over: { html?: typeof FRAME; md?: typeof FRAME } = {}) =>
    ctx({
      cards: [
        { id: "term:t-1", kind: "term", frame: FRAME },
        { id: "doc:/a/b.md", kind: "doc", frame: over.md ?? FRAME },
        { id: "doc:/a/c.html", kind: "doc", frame: over.html ?? FRAME },
        { id: "doc:/a/C.HTM", kind: "doc", frame: FRAME },
      ],
    });

  it("selects a markdown card, then drops focus to the page body", () => {
    expect(routeVerb({ t: "focus", card: "/a/b.md" }, docs())).toEqual({
      kind: "dispatch",
      steps: [
        { target: "card-body", card: "doc:/a/b.md", events: ["pointerdown", "pointerup"] },
        { target: "page-body", card: null, events: ["focus"] },
      ],
    });
  });

  it("selects an HTML card, lifts its shield, then focuses its iframe", () => {
    expect(routeVerb({ t: "focus", card: "/a/c.html" }, docs())).toEqual({
      kind: "dispatch",
      steps: [
        { target: "card-body", card: "doc:/a/c.html", events: ["pointerdown", "pointerup"] },
        { target: "doc-shield", card: "doc:/a/c.html", events: ["dblclick"] },
        { target: "doc-iframe", card: "doc:/a/c.html", events: ["focus"] },
      ],
    });
  });

  it("routes .HTM as HTML, ignoring case", () => {
    expect(routeVerb({ t: "focus", card: "/a/C.HTM" }, docs())).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-body" }, { target: "doc-shield" }, { target: "doc-iframe" }],
    });
  });

  it("still refuses the prefixed id", () => {
    expect(routeVerb({ t: "focus", card: "doc:/a/b.md" }, docs())).toEqual({
      kind: "error",
      error: "no_such_card",
    });
  });

  it("refuses a culled HTML card with card_hidden, and nothing else", () => {
    // Kept region for this context: x in (−1500, 1500), y in (−1200, 1200).
    const far = { x: 10000, y: 0, w: 400, h: 300 };
    expect(routeVerb({ t: "focus", card: "/a/c.html" }, docs({ html: far }))).toEqual({
      kind: "error",
      error: "card_hidden",
    });
    // Inside ±1500 but outside ±1200 and ±500: pins the same predicate the
    // board culls with (w/h not swapped, one-view margin kept).
    const edge = { x: 1300, y: 0, w: 400, h: 300 };
    expect(routeVerb({ t: "focus", card: "/a/c.html" }, docs({ html: edge }))).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-body" }, { target: "doc-shield" }, { target: "doc-iframe" }],
    });
    // The markdown plan works on a culled card.
    expect(routeVerb({ t: "focus", card: "/a/b.md" }, docs({ md: far }))).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-body" }, { target: "page-body" }],
    });
    // card_hidden is focus's alone.
    expect(routeVerb({ t: "type", card: "/a/c.html", text: "x" }, docs({ html: far }))).toEqual({
      kind: "error",
      error: "unsupported_card_kind",
    });
    expect(routeVerb({ t: "key", card: "/a/c.html", combo: "enter" }, docs({ html: far }))).toEqual({
      kind: "error",
      error: "unsupported_card_kind",
    });
    expect(routeVerb({ t: "resize", card: "/a/c.html", w: 1, h: 1 }, docs({ html: far }))).toMatchObject({
      kind: "dispatch",
      steps: [{ target: "card-handle-br", card: "doc:/a/c.html" }],
    });
  });

  it("still refuses type and key on either doc kind", () => {
    for (const card of ["/a/b.md", "/a/c.html"]) {
      expect(routeVerb({ t: "type", card, text: "x" }, docs())).toEqual({
        kind: "error",
        error: "unsupported_card_kind",
      });
      expect(routeVerb({ t: "key", card, combo: "enter" }, docs())).toEqual({
        kind: "error",
        error: "unsupported_card_kind",
      });
    }
  });
});
