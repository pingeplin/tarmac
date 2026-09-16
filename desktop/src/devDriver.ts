// The QA driver's frontend half (spec 2609.0015, issue #166) — untested shell by
// design: every decision it makes is a call into `kit/dev*`, and what is left is
// wiring (find the element, dispatch the event, read the DOM, reply).
//
// Installed only in a dev build, behind `import.meta.env.DEV`, so Vite
// dead-code-eliminates the whole module out of a production bundle. That is the
// third of the three gates; the other two are Rust `#[cfg(debug_assertions)]` on
// the CLI verb and on the backend endpoint.
//
// Principle: INJECT EVENTS, DON'T CALL HANDLERS. The bugs this exists to catch
// live in component pointer handlers, so the driver dispatches real DOM events on
// the real targets and lets React and xterm's own listeners run. `zoom` is the
// one exception in the other direction — a pure view transform with no cited bug
// — and goes through the engine's viewport commit so `Msg::Layout` still fires.

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { TermHandle } from "./cards/TerminalCard";
import type { BoardEngine } from "./board/BoardEngine";
import {
  buildSnapshot,
  bareCardId,
  tailWindowBounds,
  type DevCardInput,
  type DevSelectionType,
} from "./kit/devSnapshot";
import { routeVerb, DEV_ERROR_MESSAGE, type DevVerb, type RouteStep } from "./kit/devRouting";
import { parseUntil, evalUntil } from "./kit/devUntil";
import { devKeyPlan, contextMenuPlan, type KeyDescriptor } from "./kit/devKeyPlan";
import { devCellPoint } from "./kit/devCellPoint";
import { devTypePlan, devTypeSummary } from "./kit/devTypePlan";
import { gripDelta, gripPlan, type PointerDescriptor } from "./kit/devResizeGrip";
import { xtermKittyFlags } from "./cards/xtermKittyFlags";

/** Everything the driver cannot reach from outside React. */
export interface DevDriverDeps {
  activeBoardId(): string;
  engine(): BoardEngine | null;
  /** The ACTIVE board's cards, with internal (prefixed) ids. */
  cards(): DevCardInput[];
  terminal(termId: string): TermHandle | undefined;
  selectedId(): string | null;
  /** The daemon's last TermProc name for a terminal, if it has reported one. */
  proc(termId: string): string | null;
}

/** How long the settle waits when animation frames are not being serviced.
 *  WebKit is documented to throttle rAF for an occluded window, which is this
 *  driver's most normal usage (called from a shell, Tarmac behind the terminal).
 *  Unverified here — Q5 observes it — so the cap bounds the risk rather than
 *  claiming the behaviour. It can only ever end the wait early. */
const SETTLE_CAP_MS = 100;
/** `--until` re-evaluates on a timer, not a rAF loop: every fact it waits on (a
 *  ResizeObserver round trip, the daemon's 750 ms TermProc poll, a debounced
 *  persist) is slower than a frame, and a rAF spin competes with the render it
 *  is waiting for. */
const POLL_MS = 50;

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const twoFrames = () =>
  new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r())));

const fail = (error: string, message: string, extra: Record<string, unknown> = {}) => ({
  ok: false,
  body: JSON.stringify({ error, message, ...extra }),
});

export function installDevDriver(deps: DevDriverDeps): () => void {
  let stopped = false;
  let unlisten: UnlistenFn | null = null;
  // Requests are served one at a time, so every reply describes the state its
  // own verb produced and not a neighbour's.
  let queue: Promise<unknown> = Promise.resolve();

  void listen<{ id: number; req: Record<string, unknown> }>("dev-request", (e) => {
    const { id, req } = e.payload;
    queue = queue
      .then(async () => {
        const reply = await handle(req, deps);
        await invoke("dev_reply", { id, ok: reply.ok, body: reply.body });
      })
      // Load-bearing: without it one rejection poisons the chain — every later
      // `.then` would be skipped and every subsequent request would come back
      // `app_unresponsive` with nothing said, which a `make qa` run would blame
      // on the backend.
      .catch(async (e) => {
        const body = JSON.stringify({ error: "driver_threw", message: String(e) });
        await invoke("dev_reply", { id, ok: false, body }).catch(() => {});
      });
  }).then((un) => {
    if (stopped) {
      un();
      return;
    }
    unlisten = un;
    // Only now: the backend cannot distinguish "no listener yet" from "a
    // listener that never answered" without this.
    void invoke("dev_ready");
  });

  return () => {
    stopped = true;
    unlisten?.();
  };
}

async function handle(raw: Record<string, unknown>, deps: DevDriverDeps) {
  const engine = deps.engine();
  if (!engine) return fail("app_not_ready", "no board engine on the active board");

  // `snapshot` reads state and dispatches nothing, so it never routes — which is
  // why `DevVerb` does not include it and this branch comes first.
  if (raw.t === "snapshot") {
    return snapshotReply(raw as Parameters<typeof snapshotReply>[0], deps, engine);
  }

  // Answered from the verb alone, before routing: routing would otherwise reply
  // `no_such_card` or `not_focused` for a verb this build does not implement at
  // all — three different answers to one question.
  if (!IMPLEMENTED.has(raw.t as string)) {
    return fail(
      "unsupported_verb",
      `\`${raw.t}\` lands in stage 2 of issue #166; this build implements ${[...IMPLEMENTED].join(", ")}`,
    );
  }

  // `Focus { card: None }` arrives with no `card` key at all (the encoder skips
  // it), so normalise before routing rather than letting `undefined` through.
  const verb = { ...raw, card: (raw.card as string | undefined) ?? null } as unknown as DevVerb;
  const cards = deps.cards();
  const nodes = cardNodes(deps, engine);
  const route = routeVerb(verb, {
    cards,
    // Only `type`/`key` consult it, and both are stage 2 — but routing takes a
    // value, so it is computed once here and reused by the reply's snapshot.
    activeElementCard: activeElementCard(cards, nodes),
  });
  if (route.kind === "error") {
    return fail(route.error, DEV_ERROR_MESSAGE[route.error], {
      card: "card" in verb ? verb.card : null,
    });
  }

  if (route.kind === "viewport") {
    // The engine's own commit — the same path the wheel gesture ends in, so
    // `onViewportChange` fires and `Msg::Layout` still lands. It also clamps,
    // which is why the reply reads the zoom back rather than echoing `z`.
    engine.setViewport({ ...engine.viewport, zoom: (verb as { z: number }).z });
    await settle();
    // The observed zoom, not the requested one: the engine clamps to [0.1, 3.0].
    return { ok: true, body: JSON.stringify({ zoom: engine.viewport.zoom }) };
  }

  // Routing has already resolved the card and checked the preconditions, so each
  // verb below only has to plan its own events and report what it observed.
  if (verb.t === "resize") return resizeVerb(verb, route.steps[0], deps, engine);
  if (verb.t === "type") return typeVerb(verb, route.steps[0], deps, engine);
  if (verb.t === "key") return keyVerb(verb, route.steps[0], deps, engine);

  for (const step of route.steps) dispatchStep(step, deps, engine);
  await settle();
  const snap = build(deps, engine);
  return {
    ok: true,
    body: JSON.stringify({ focused_card: snap.focused_card, active_element: snap.active_element }),
  };
}

/** Drags the bottom-right grip. `from`/`to` are read off the card's frame before
 *  and after, so the reply reports where the card LANDED — including the
 *  160×90 minimum clamp — rather than echoing the request. */
async function resizeVerb(
  verb: { card: string; w: number; h: number },
  step: RouteStep,
  deps: DevDriverDeps,
  engine: BoardEngine,
) {
  const grip = requireElement(step, deps, engine);
  const from = requireFrame(step.card, deps);
  const delta = gripDelta(from, { w: verb.w, h: verb.h }, engine.viewport.zoom);
  const r = grip.getBoundingClientRect();
  const centre = { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  for (const d of gripPlan(centre, delta)) grip.dispatchEvent(pointerEvent(d));
  await settle();
  const to = requireFrame(step.card, deps);
  return json({
    from: { w: from.w, h: from.h },
    to: { w: to.w, h: to.h },
    delta_px: delta,
  });
}

/** Each printable goes in through `execCommand`, bracketed by the plan's inert
 *  keydown/keyup — the `beforeinput` path #162 broke, and the only one a scenario
 *  can prove. Under kitty flag 8 the plan switches to key events and nothing is
 *  inserted (S77); the reply's `mode` says which happened. */
async function typeVerb(
  verb: { card: string; text: string },
  step: RouteStep,
  deps: DevDriverDeps,
  engine: BoardEngine,
) {
  const term = requireTerminal(step, deps);
  const textarea = requireElement(step, deps, engine);
  const plan = devTypePlan(verb.text, xtermKittyFlags(term));
  const inserted: boolean[] = [];
  for (const s of plan.steps) {
    if (s.kind === "key") {
      for (const d of s.events) textarea.dispatchEvent(keyEvent(d));
      continue;
    }
    textarea.dispatchEvent(keyEvent(s.keydown));
    // The precondition guarantees this textarea holds focus, which is what
    // execCommand acts on. Its return value IS the dropped/inserted fact.
    inserted.push(document.execCommand("insertText", false, s.char));
    textarea.dispatchEvent(keyEvent(s.keyup));
  }
  await settle();
  return json(devTypeSummary(plan, inserted));
}

async function keyVerb(
  verb: { card: string; combo: string },
  step: RouteStep,
  deps: DevDriverDeps,
  engine: BoardEngine,
) {
  const plan = devKeyPlan(verb.combo);
  if (plan.kind === "error") return fail(plan.error, plan.message, { combo: verb.combo });

  const term = requireTerminal(step, deps);
  const element = requireElement(step, deps, engine);
  const events =
    plan.kind === "contextmenu"
      ? dispatchContextMenu(term, element)
      : dispatchKeys(plan.events, element);
  if ("error" in events) return fail(events.error, events.message, { card: verb.card });
  await settle();
  return json({ combo: verb.combo, events });
}

function dispatchKeys(descriptors: KeyDescriptor[], element: HTMLElement): string[] {
  for (const d of descriptors) element.dispatchEvent(keyEvent(d));
  return descriptors.map((d) => d.type);
}

/** The mouse pair, at the centre of the last written cell. The rect handed to
 *  `devCellPoint` must be the UNPATCHED one — TerminalCard patches
 *  getBoundingClientRect on this very element, and the patched rect carries a
 *  stale mouse anchor. See kit/devCellPoint for why that cancels out. */
function dispatchContextMenu(
  term: TermHandle,
  element: HTMLElement,
): string[] | { error: "empty_buffer"; message: string } {
  const screen = term.screenElement;
  if (!screen) throw new Error("the terminal has no screen element to right-click");
  const r = Element.prototype.getBoundingClientRect.call(screen);
  const buffer = term.buffer.active;
  const lines: string[] = [];
  for (let i = 0; i < term.rows; i++) {
    lines.push(buffer.getLine(buffer.viewportY + i)?.translateToString(true) ?? "");
  }
  const point = devCellPoint({
    lines,
    screenRect: { x: r.x, y: r.y, w: r.width, h: r.height },
    cols: term.cols,
    rows: term.rows,
  });
  if ("error" in point) return point;
  const plan = contextMenuPlan(point);
  for (const d of plan) element.dispatchEvent(new MouseEvent(d.type, d));
  return plan.map((d) => d.type);
}

const json = (body: unknown) => ({ ok: true, body: JSON.stringify(body) });

/** `keyCode` and `which` are legacy KeyboardEventInit members, absent from the
 *  standard typings. WebKit honours them (measured, #174 pre-check 5), and it has
 *  to: xterm's evaluator reads `keyCode`, so an event without it encodes nothing
 *  and the verb is a silent no-op that still reports success. */
const keyEvent = (d: KeyDescriptor) => new KeyboardEvent(d.type, d as KeyboardEventInit);
const pointerEvent = (d: PointerDescriptor) => new PointerEvent(d.type, d);

function requireElement(step: RouteStep, deps: DevDriverDeps, engine: BoardEngine): HTMLElement {
  const el = targetElement(step, deps, engine);
  if (!el) throw new Error(`no ${step.target} element for ${step.card ?? "the board"}`);
  return el;
}

function requireTerminal(step: RouteStep, deps: DevDriverDeps): TermHandle {
  const term = deps.terminal(bareCardId(step.card ?? ""));
  if (!term) throw new Error(`no live terminal behind ${step.card}`);
  return term;
}

function requireFrame(cardId: string | null, deps: DevDriverDeps) {
  const card = deps.cards().find((c) => c.id === cardId);
  if (!card) throw new Error(`card ${cardId} vanished mid-verb`);
  return card.frame;
}

async function snapshotReply(
  verb: { t: "snapshot"; until?: string | null; timeout_ms?: number | null },
  deps: DevDriverDeps,
  engine: BoardEngine,
) {
  const src = verb.until ?? null;
  if (src === null) return { ok: true, body: JSON.stringify(build(deps, engine)) };

  const parsed = parseUntil(src);
  if ("error" in parsed) {
    // Answered at once: an expression that can never hold must not spend the
    // whole budget pretending it might.
    return fail("bad_expr", parsed.error, { expr: src });
  }
  const budget = verb.timeout_ms ?? 5000;
  const deadline = Date.now() + budget;
  let snap = build(deps, engine);
  // `--timeout 0` means evaluate once, so the check precedes the first wait.
  while (!evalUntil(parsed, snap)) {
    if (Date.now() >= deadline) {
      return fail("timeout", `\`${src}\` did not hold within ${budget}ms`, {
        expr: src,
        timeout_ms: budget,
        snapshot: snap,
      });
    }
    await sleep(POLL_MS);
    snap = build(deps, engine);
  }
  return { ok: true, body: JSON.stringify(snap) };
}

const settle = () => Promise.race([twoFrames(), sleep(SETTLE_CAP_MS)]);

/** The verbs this build dispatches. Kept as a set so a newer CLI meeting an older
 *  app gets `unsupported_verb` rather than a routing error that blames its
 *  spelling. */
const IMPLEMENTED = new Set(["snapshot", "zoom", "focus", "resize", "type", "key"]);

/** Throws rather than no-op: routing has already said this card exists, so a
 *  missing element is a real failure. Replying `ok` after dispatching nothing is
 *  the shape Decision 6 refuses. */
function dispatchStep(step: RouteStep, deps: DevDriverDeps, engine: BoardEngine) {
  const el = requireElement(step, deps, engine);
  const rect = el.getBoundingClientRect();
  const clientX = rect.x + rect.width / 2;
  const clientY = rect.y + rect.height / 2;
  for (const type of step.events) {
    const init = { bubbles: true, cancelable: true, clientX, clientY, button: 0 };
    el.dispatchEvent(
      type.startsWith("pointer")
        ? new PointerEvent(type, { ...init, pointerId: 1, pointerType: "mouse", isPrimary: true })
        : new MouseEvent(type, init),
    );
  }
}

function targetElement(
  step: RouteStep,
  deps: DevDriverDeps,
  engine: BoardEngine,
): HTMLElement | null {
  if (step.target === "board-viewport") return engine.viewportElement;
  if (step.card === null) return null;
  const node = engine.cardNode(step.card);
  if (!node) return null;
  switch (step.target) {
    case "card-body":
      return node.querySelector<HTMLElement>(".card-body");
    case "card-handle-br":
      return node.querySelector<HTMLElement>(".card-handle.br");
    case "term-element":
    case "term-textarea": {
      const term = deps.terminal(bareCardId(step.card));
      const el = step.target === "term-element" ? term?.element : term?.textarea;
      return (el as HTMLElement | undefined) ?? null;
    }
    default:
      return null;
  }
}

/** Every card's node, resolved once. `BoardEngine.cardNode` is a linear scan, and
 *  a snapshot looks every card up twice — once to measure, once to locate focus. */
function cardNodes(deps: DevDriverDeps, engine: BoardEngine): Map<string, HTMLElement> {
  const nodes = new Map<string, HTMLElement>();
  for (const card of deps.cards()) {
    const node = engine.cardNode(card.id);
    if (node) nodes.set(card.id, node);
  }
  return nodes;
}

function activeElementCard(cards: DevCardInput[], nodes: Map<string, HTMLElement>): string | null {
  const active = document.activeElement as HTMLElement | null;
  if (!active) return null;
  // Terminals carry the hook already: `.term-host` is tagged with data-term-id,
  // which is how App's own focusedLiveTermId works.
  const host = active.closest?.(".term-host") as HTMLElement | null;
  if (host?.dataset.termId) return host.dataset.termId;
  for (const card of cards) {
    if (nodes.get(card.id)?.contains(active)) return bareCardId(card.id);
  }
  return null;
}

function build(deps: DevDriverDeps, engine: BoardEngine) {
  const cards = deps.cards();
  const nodes = cardNodes(deps, engine);
  const viewRect = engine.viewportElement.getBoundingClientRect();
  const screenRects = new Map<string, { x: number; y: number; w: number; h: number }>();
  for (const [id, node] of nodes) {
    const r = node.getBoundingClientRect();
    screenRects.set(id, { x: r.x, y: r.y, w: r.width, h: r.height });
  }
  const active = document.activeElement as HTMLElement | null;
  return buildSnapshot({
    boardId: deps.activeBoardId(),
    visibilityState: document.visibilityState === "hidden" ? "hidden" : "visible",
    viewport: engine.viewport,
    viewRect: { x: viewRect.x, y: viewRect.y, w: viewRect.width, h: viewRect.height },
    cards: cards.map((c) => (c.kind === "term" ? { ...c, term: termFacts(c, deps) } : c)),
    screenRects,
    selectedId: deps.selectedId(),
    activeElement: {
      card: activeElementCard(cards, nodes),
      tag: active?.tagName ?? "",
      classes: active ? Array.from(active.classList) : [],
      selectionType: (window.getSelection()?.type ?? "None") as DevSelectionType,
    },
  });
}

function termFacts(card: DevCardInput, deps: DevDriverDeps) {
  const termId = bareCardId(card.id);
  const term = deps.terminal(termId);
  if (!term) return { cols: 0, rows: 0, proc: null, selection: null, lines: [], cursorLine: 0 };
  const buffer = term.buffer.active;
  const cursorLine = buffer.baseY + buffer.cursorY;
  // Only the window the snapshot will keep. A terminal holds 5000 lines of
  // scrollback and reports ~40, and this runs once per 50 ms `--until` poll —
  // reading the whole buffer would make the cost grow with session length.
  const { start, end } = tailWindowBounds(cursorLine, buffer.length);
  const lines: string[] = [];
  for (let y = start; y <= end; y++) {
    lines.push(buffer.getLine(y)?.translateToString(true) ?? "");
  }
  return {
    cols: term.cols,
    rows: term.rows,
    proc: deps.proc(termId),
    // Verbatim; kit/devSnapshot normalises xterm's "" to null, because that is a
    // decision and this file is wiring.
    selection: term.getSelection(),
    // `lines` is the window, `cursorLine` is still absolute — `scrollbackTail`
    // recomputes the same bounds and selects the whole window back out.
    lines,
    cursorLine,
  };
}
