// Which element each QA-driver verb dispatches on, and which preconditions are
// checked before anything is dispatched (spec 2609.0015, issue #166).
//
// The routing is a decision, not wiring, because getting it wrong produces a
// scenario that passes while testing the wrong thing:
//   - `focus` needs BOTH halves. CardShell's body pointerdown only raises the
//     card; xterm focuses its textarea from its own mousedown listener.
//   - `focus board` must land ON the board viewport node: Board.tsx gates the
//     blur branch on `e.target` identity, so a bubbled event never satisfies it.
//   - `key contextmenu` goes to the xterm element, not the textarea. The textarea
//     would yield a Caret where the scenario needs a Range.
//   - the card KIND is checked before focus, so the error names a property of the
//     request rather than of wherever focus happened to be.

import { bareCardId, type DevCardInput } from "./devSnapshot";

export type DevTarget =
  | "card-body"
  | "term-element"
  | "term-textarea"
  | "card-handle-br"
  | "board-viewport";

export type DevErrorCode = "no_such_card" | "not_focused" | "unsupported_card_kind";

export interface RouteStep {
  target: DevTarget;
  /** The app-internal (prefixed) card id, or null for the board itself. */
  card: string | null;
  events: string[];
}

export type Route =
  | { kind: "dispatch"; steps: RouteStep[] }
  /** `zoom` commits through BoardEngine.setViewport, not through an event. */
  | { kind: "viewport" }
  | { kind: "error"; error: DevErrorCode };

export interface RouteContext {
  /** The ACTIVE board's cards only. A hidden board's cards are mounted but
   *  display:none, so dispatching to one would produce events no snapshot could
   *  observe — they are absent here, and so are `no_such_card`. */
  cards: DevCardInput[];
  /** The bare id of the card holding document.activeElement, if any. */
  activeElementCard: string | null;
}

export type DevVerb =
  | { t: "snapshot" }
  | { t: "zoom"; z: number }
  | { t: "focus"; card: string | null }
  | { t: "resize"; card: string; w: number; h: number }
  | { t: "type"; card: string; text: string }
  | { t: "key"; card: string; combo: string };

const CONTEXT_MENU = "contextmenu";

export function routeVerb(verb: DevVerb, ctx: RouteContext): Route {
  if (verb.t === "zoom") return { kind: "viewport" };
  if (verb.t === "snapshot") return { kind: "dispatch", steps: [] };
  if (verb.t === "focus" && verb.card === null) {
    return {
      kind: "dispatch",
      steps: [{ target: "board-viewport", card: null, events: ["pointerdown"] }],
    };
  }

  const card = ctx.cards.find((c) => bareCardId(c.id) === verb.card);
  if (!card) return { kind: "error", error: "no_such_card" };

  if (verb.t === "resize") {
    // A doc card resizes like any other; only the focus-bearing verbs need a
    // terminal.
    return {
      kind: "dispatch",
      steps: [{ target: "card-handle-br", card: card.id, events: ["pointerdown", "pointermove", "pointerup"] }],
    };
  }

  if (card.kind !== "term") return { kind: "error", error: "unsupported_card_kind" };

  if (verb.t === "focus") {
    return {
      kind: "dispatch",
      steps: [
        { target: "card-body", card: card.id, events: ["pointerdown", "pointerup"] },
        { target: "term-element", card: card.id, events: ["mousedown", "mouseup"] },
      ],
    };
  }

  // type / key: focus must ALREADY be right, so a passing verb proves it rather
  // than establishing it.
  if (ctx.activeElementCard !== verb.card) return { kind: "error", error: "not_focused" };

  if (verb.t === "key" && verb.combo === CONTEXT_MENU) {
    return {
      kind: "dispatch",
      steps: [{ target: "term-element", card: card.id, events: ["mousemove", "contextmenu"] }],
    };
  }
  return {
    kind: "dispatch",
    steps: [{ target: "term-textarea", card: card.id, events: [] }],
  };
}
