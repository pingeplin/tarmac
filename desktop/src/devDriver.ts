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
import type { Terminal } from "@xterm/xterm";
import type { BoardEngine } from "./board/BoardEngine";
import { buildSnapshot, bareCardId, type DevCardInput, type DevSelectionType } from "./kit/devSnapshot";
import { routeVerb, type DevVerb, type RouteStep } from "./kit/devRouting";
import { parseUntil, evalUntil } from "./kit/devUntil";

/** Everything the driver cannot reach from outside React. */
export interface DevDriverDeps {
  activeBoardId(): string;
  engine(): BoardEngine | null;
  /** The ACTIVE board's cards, with internal (prefixed) ids. */
  cards(): DevCardInput[];
  terminal(termId: string): Terminal | undefined;
  selectedId(): string | null;
  /** The daemon's last TermProc name for a terminal, if it has reported one. */
  proc(termId: string): string | null;
  /** Commit a zoom through the same path the wheel gesture ends in. */
  setZoom(z: number): void;
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

  // `Focus { card: None }` arrives with no `card` key at all (the encoder skips
  // it), so normalise before routing rather than letting `undefined` through.
  const verb = { ...raw, card: (raw.card as string | undefined) ?? null } as unknown as DevVerb;
  const route = routeVerb(verb, {
    cards: deps.cards(),
    activeElementCard: activeElementCard(deps, engine),
  });
  if (route.kind === "error") {
    return fail(route.error, describe(route.error), { card: "card" in verb ? verb.card : null });
  }

  if (route.kind === "viewport") {
    const z = (verb as { z: number }).z;
    deps.setZoom(z);
    await settle();
    // The observed zoom, not the requested one: the engine clamps to [0.1, 3.0].
    return { ok: true, body: JSON.stringify({ zoom: engine.viewport.zoom }) };
  }

  if (verb.t !== "focus") {
    return fail(
      "unsupported_verb",
      `\`${verb.t}\` lands in stage 2 of issue #166; this build implements snapshot, zoom and focus`,
    );
  }

  for (const step of route.steps) dispatchStep(step, deps, engine);
  await settle();
  const snap = build(deps, engine);
  return {
    ok: true,
    body: JSON.stringify({ focused_card: snap.focused_card, active_element: snap.active_element }),
  };
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

function describe(error: string): string {
  switch (error) {
    case "no_such_card":
      return "no card with that id on the active board";
    case "not_focused":
      return "that card does not hold keyboard focus; `tarmac dev focus <card>` first";
    case "unsupported_card_kind":
      return "doc cards have no focus target an untrusted event can reach";
    default:
      return error;
  }
}

/** Throws rather than no-op: routing has already said this card exists, so a
 *  missing element is a real failure. Replying `ok` after dispatching nothing is
 *  the shape Decision 6 refuses. */
function dispatchStep(step: RouteStep, deps: DevDriverDeps, engine: BoardEngine) {
  const el = targetElement(step, deps, engine);
  if (!el) throw new Error(`no ${step.target} element for ${step.card ?? "the board"}`);
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

function activeElementCard(deps: DevDriverDeps, engine: BoardEngine): string | null {
  const active = document.activeElement as HTMLElement | null;
  if (!active) return null;
  // Terminals carry the hook already: `.term-host` is tagged with data-term-id,
  // which is how App's own focusedLiveTermId works.
  const host = active.closest?.(".term-host") as HTMLElement | null;
  if (host?.dataset.termId) return host.dataset.termId;
  for (const card of deps.cards()) {
    if (engine.cardNode(card.id)?.contains(active)) return bareCardId(card.id);
  }
  return null;
}

function build(deps: DevDriverDeps, engine: BoardEngine) {
  const cards = deps.cards();
  const viewRect = engine.viewportElement.getBoundingClientRect();
  const screenRects = new Map<string, { x: number; y: number; w: number; h: number }>();
  for (const c of cards) {
    const node = engine.cardNode(c.id);
    if (!node) continue;
    const r = node.getBoundingClientRect();
    screenRects.set(c.id, { x: r.x, y: r.y, w: r.width, h: r.height });
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
      card: activeElementCard(deps, engine),
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
  const lines: string[] = [];
  for (let y = 0; y < buffer.length; y++) {
    lines.push(buffer.getLine(y)?.translateToString(true) ?? "");
  }
  return {
    cols: term.cols,
    rows: term.rows,
    proc: deps.proc(termId),
    // Verbatim; kit/devSnapshot normalises xterm's "" to null, because that is a
    // decision and this file is wiring.
    selection: term.getSelection(),
    lines,
    cursorLine: buffer.baseY + buffer.cursorY,
  };
}
