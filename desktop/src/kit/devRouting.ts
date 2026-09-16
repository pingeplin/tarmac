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
import { CONTEXT_MENU } from "./devKeyPlan";

export type DevTarget =
  | "card-body"
  | "term-element"
  | "term-textarea"
  | "card-handle-br"
  | "board-viewport";

export type DevErrorCode = "no_such_card" | "not_focused" | "unsupported_card_kind";

/** What each refusal means, in the words the caller sees. A Record rather than a
 *  switch so adding a code is a type error until its message exists. */
export const DEV_ERROR_MESSAGE: Record<DevErrorCode, string> = {
  no_such_card: "no card with that id on the active board",
  not_focused: "that card does not hold keyboard focus; `tarmac dev focus <card>` first",
  unsupported_card_kind: "doc cards have no focus target an untrusted event can reach",
};

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

/** Every verb that routes. `snapshot` is deliberately absent: it reads state and
 *  dispatches nothing, so it is answered before routing and the type system is
 *  what keeps it out of here. */
export type DevVerb =
  | { t: "zoom"; z: number }
  | { t: "focus"; card: string | null }
  | { t: "resize"; card: string; w: number; h: number }
  | { t: "type"; card: string; text: string }
  | { t: "key"; card: string; combo: string };

export function routeVerb(verb: DevVerb, ctx: RouteContext): Route {
  if (verb.t === "zoom") return { kind: "viewport" };
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
    // terminal. Events are empty for the same reason as `type`/`key` below: a
    // drag needs a coordinate PER event, which `RouteStep` does not carry, so
    // naming the three pointer events here would pin a plan that dispatches them
    // all at the grip's centre — a zero-delta drag that cannot resize anything.
    return {
      kind: "dispatch",
      steps: [{ target: "card-handle-br", card: card.id, events: [] }],
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
    // Events empty for the same reason as the three below: the pair comes from
    // `devKeyPlan.contextMenuPlan`, which needs a coordinate per event that a
    // `RouteStep` cannot carry. Naming them here too would leave a second,
    // unread list for a reader to change by mistake.
    return {
      kind: "dispatch",
      steps: [{ target: "term-element", card: card.id, events: [] }],
    };
  }
  // The events themselves come from `devKeyPlan`/`devTypePlan`; the routing
  // decision — which element, and whether the preconditions hold — is what lives
  // here, and it is the same either way.
  return {
    kind: "dispatch",
    steps: [{ target: "term-textarea", card: card.id, events: [] }],
  };
}
