// The cockpit orchestrator: subscribes to the daemon stream, owns per-board state
// (P5 multi-board), runs the multi-terminal lifecycle (boot/⌘T/exit/prime), lands
// `tarmac open` docs with gravity placement + a provenance edge, parks docs on a
// shelf, and round-trips the layout (tiles + viewport) to the daemon. Phase 4 adds
// the wayfinding + feedback chrome: zoom control, minimap, offscreen-signal hints
// (+ ⏎ fly / Esc fly-back), the ⌘P peek slide-over, transient toasts, the session
// chip, and full card-chrome states (selection ring, resize handles, quiet/detached).
// Phase 5 adds the multi-board model + ⌘K switcher.
//
// WARM-BOARD MODEL: App renders ONE <Board> per board simultaneously; inactive
// boards are display:none (hidden=true) so their xterm terminals stay mounted and
// streaming. Board switch is instant — no re-mount, no scrollback loss.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Board } from "./board/Board";
import { StatusBar } from "./ui/StatusBar";
import { ShelfOverlay } from "./ui/ShelfOverlay";
import { ZoomControl } from "./ui/ZoomControl";
import { MinimapOverlay, type MinimapItem, type MinimapSignal } from "./ui/MinimapOverlay";
import { OffscreenHints } from "./ui/OffscreenHints";
import { PeekOverlay } from "./ui/PeekOverlay";
import { ToastOverlay } from "./ui/ToastOverlay";
import { BoardSwitcher } from "./ui/BoardSwitcher";
import { TitleBarChip } from "./ui/TitleBarChip";
import { DockPane } from "./ui/DockPane";
import { CycleHud } from "./ui/CycleHud";
import { DockContext, type DockContextValue } from "./cards/DockContext";
import { cycleOrder, step } from "./kit/termCycle";
import type { BoardEngine, Viewport } from "./board/BoardEngine";
import {
  cardId,
  emptyBoardState,
  topZ,
  type BoardState,
  type CardModel,
  type DocCardModel,
  type DocMeta,
  type TermCardModel,
  type WorldFrame,
} from "./board/model";
import { mint } from "./kit/bootTerminal";
import { displayLabel } from "./kit/termTitle";
import { decide } from "./kit/termExit";
import { plan } from "./kit/termRestore";
import { cascadeOrigin, isOffscreen } from "./kit/boardWayfinding";
import {
  pillLabel,
  selectFlyTarget,
  stackPills,
  type OffscreenHint,
  type PlacedPill,
  type Signal,
} from "./kit/offscreenHints";
import {
  addToast,
  clearAllToasts,
  dismissToast,
  emptyToasts,
  pruneExpired,
  type Toast,
  type ToastState,
} from "./kit/toasts";
import { boardChipLabel } from "./kit/chromeText";
import { docDisplayPath } from "./kit/docStore";
import { Place, firstFreeSlot, scatterFrame } from "./kit/placement";
import { buildTiles, parseTiles, type LayoutTile } from "./kit/layoutTiles";
import type { Size } from "./kit/geom";
import {
  frontendReady,
  onDaemonMsg,
  onDaemonStatus,
  persistLayout,
  readDoc,
  spawnTerm,
  termResize,
  boardSwitch,
  boardCreate,
  boardRename,
  boardDelete,
} from "./ipc/daemon";
import type { DaemonMsg, DaemonStatus, WireBoardMeta } from "./ipc/protocol";
import {
  rows as switcherRows,
  boardIdForOrdinal,
  clampSelection,
  canDelete,
  sanitizedName,
  isTypable,
  liveness,
  type BoardSummary,
  type BoardRow,
} from "./kit/boardSwitcher";
import { TermBoardIndex } from "./kit/termBoardIndex";
import { isComposingKey } from "./kit/imeGuard";

const BOOT_FRAME: WorldFrame = { ...Place.termFrame };
const PERSIST_DEBOUNCE_MS = 200;
const ZOOM_STEP = 1.2; // ZoomControl.zoomStep — ± multiply/divide by this
const TOAST_PRUNE_MS = 250;

// Offscreen-hint layout constants (OffscreenHints.swift).
const HINT_EDGE_INSET = 18;
const HINT_EDGE_MARGIN = 10;
const HINT_STACK_GAP = 8;

/** The in-flight header drag: a term carries its attached doc satellites so they
 * translate with it (gravity); a doc carries only its path (drag detaches it). */
type Gesture =
  | { kind: "term"; termId: string; startFrame: WorldFrame; sats: Map<string, WorldFrame> }
  | { kind: "doc"; path: string };

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

/** A card's wayfinding signal (bell outranks live); docs carry none yet. */
const cardSignal = (c: CardModel): Signal | null => {
  if (c.kind === "term") {
    if (c.bell) return "bell";
    if (c.live && !c.dead) return "live";
  }
  return null;
};

/** HH:MM for a bell pill (view-layer clock; the kit takes the formatted string). */
const formatClock = (ms: number): string => {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
};

/** Approximate pill size from mono metrics (IBM Plex Mono ~6.3px/char at 10.5px)
 * + arrow + horizontal padding — feeds the pure stacking layout. */
const measurePill = (h: OffscreenHint): Size => ({ w: 22 + 8 + 7 + h.label.length * 6.3, h: 26 });

// --- Synthetic board id used before the first real restore arrives -------------
// We seed a single synthetic board so the UI renders before the daemon responds.
const SYNTHETIC_ID = "";

export default function App() {
  // --- per-board state (P5 multi-board) ----------------------------------------
  // A Map<boardId, BoardState>: one entry per board that has been visited this
  // session. Never-visited boards have no local state until their first restore.
  const [boards, setBoards] = useState<Map<string, BoardState>>(
    () => new Map([[SYNTHETIC_ID, emptyBoardState()]]),
  );
  const [activeBoardId, setActiveBoardId] = useState<string>(SYNTHETIC_ID);
  const [boardMetas, setBoardMetas] = useState<WireBoardMeta[]>([]);

  // Ref mirrors of the above for use inside stale closure callbacks (daemon handler,
  // keydown handler, persist timer).
  const boardsRef = useRef<Map<string, BoardState>>(boards);
  boardsRef.current = boards;
  const activeIdRef = useRef<string>(activeBoardId);
  activeIdRef.current = activeBoardId;
  // Mirror of boardMetas for the once-registered keydown closure (which calls
  // buildSummaries → must see the LATEST metas, not the first-render []).
  const boardMetasRef = useRef<WireBoardMeta[]>([]);
  boardMetasRef.current = boardMetas;

  // --- per-board engines (populated via onEngineReady callbacks) ---------------
  // The active board's engine drives the chrome (zoom/minimap/hints/fit/fly).
  // Each board's <Board> calls onEngineReady(boardId, engine) on mount/destroy.
  const enginesRef = useRef<Map<string, BoardEngine>>(new Map());
  // Stable ref to the ACTIVE board's engine (kept in sync by onEngineReady and
  // beginSwitchTo so chrome reads are always current).
  const engineRef = useRef<BoardEngine | null>(null);

  // --- TermBoardIndex: term_id → board_id routing for JSON frames --------------
  const termBoardIndexRef = useRef(new TermBoardIndex());

  // --- Phase 4 chrome state (active-board scoped) ------------------------------
  const [status, setStatus] = useState<DaemonStatus>({ connected: false, reason: "connecting…" });
  const [viewport, setViewportState] = useState<Viewport>({ zoom: 1, cx: 0, cy: 0 });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [toastState, setToastState] = useState<ToastState>(emptyToasts);
  const [peekVisible, setPeekVisible] = useState(false);
  const [peekPath, setPeekPath] = useState<string | null>(null);
  const [docContents, setDocContents] = useState<Map<string, string>>(new Map());

  // --- ⌘K switcher state (owned here; BoardSwitcher is a pure render component) -
  const [switcherOpen, setSwitcherOpen] = useState(false);
  const [switcherFilter, setSwitcherFilter] = useState("");
  const [switcherSelected, setSwitcherSelected] = useState(0);
  const [switcherEditing, setSwitcherEditing] = useState(false);
  const [switcherEditBuffer, setSwitcherEditBuffer] = useState("");
  const [switcherConfirming, setSwitcherConfirming] = useState(false);

  // --- dock pane + cycle HUD state (Wave 2) -------------------------------------
  const [dockSlot, setDockSlot] = useState<HTMLElement | null>(null);
  const [cycleHud, setCycleHud] = useState<{ labels: string[]; activeIndex: number } | null>(null);
  const cycleHudTimer = useRef<number | null>(null);

  // Switcher ref mirrors for the stale keydown closure.
  const switcherOpenRef = useRef(false);
  switcherOpenRef.current = switcherOpen;
  const switcherFilterRef = useRef("");
  switcherFilterRef.current = switcherFilter;
  const switcherSelectedRef = useRef(0);
  switcherSelectedRef.current = switcherSelected;
  const switcherEditingRef = useRef(false);
  switcherEditingRef.current = switcherEditing;
  const switcherEditBufferRef = useRef("");
  switcherEditBufferRef.current = switcherEditBuffer;
  const switcherConfirmingRef = useRef(false);
  switcherConfirmingRef.current = switcherConfirming;

  // --- misc refs ---------------------------------------------------------------
  const gestureRef = useRef<Gesture | null>(null);
  const persistTimers = useRef<Map<string, number>>(new Map());
  const lastChangedRef = useRef<Map<string, number>>(new Map());
  const bellTimeRef = useRef<Map<string, number>>(new Map());
  const peekVisibleRef = useRef(false);
  peekVisibleRef.current = peekVisible;
  const peekPathRef = useRef<string | null>(null);
  peekPathRef.current = peekPath;
  const toastsRef = useRef<Toast[]>([]);
  toastsRef.current = toastState.toasts;
  const flyTargetRef = useRef<string | null>(null);
  const preFlightRef = useRef<Viewport | null>(null);
  const prevConnectedRef = useRef(false);
  // Gates the "daemon restarted" toast to once per reconnect cycle (a full restart
  // re-sends a restore per board, which would otherwise toast N times).
  const daemonRestartToastedRef = useRef(false);
  const vpRafRef = useRef<number | null>(null);
  const pendingVpRef = useRef<Viewport | null>(null);

  // --- active-board accessors --------------------------------------------------

  const activeBoard = (): BoardState | undefined =>
    boardsRef.current.get(activeIdRef.current);

  /** Immutably update a specific board's state. */
  const setBoardState = (boardId: string, fn: (b: BoardState) => BoardState) =>
    setBoards((bs) => {
      const b = bs.get(boardId);
      if (!b) return bs;
      const n = new Map(bs);
      n.set(boardId, fn(b));
      return n;
    });

  /** Immutably update the ACTIVE board's state. */
  const setActiveBoard = (fn: (b: BoardState) => BoardState) =>
    setBoardState(activeIdRef.current, fn);

  /** Update just the cards of the active board (the most common mutation). */
  const setActiveCards = (fn: (cs: CardModel[]) => CardModel[]) =>
    setActiveBoard((b) => ({ ...b, cards: fn(b.cards) }));

  /** Update cards for a SPECIFIC board (background-routed frames). */
  const setBoardCards = (boardId: string, fn: (cs: CardModel[]) => CardModel[]) =>
    setBoardState(boardId, (b) => ({ ...b, cards: fn(b.cards) }));

  // --- focus registry (Wave 2 dock + cycle) ------------------------------------

  const termHandlesRef = useRef<Map<string, { focus(): void }>>(new Map());

  const registerTerm = useCallback((id: string, handle: { focus(): void }) => {
    termHandlesRef.current.set(id, handle);
  }, []);

  const unregisterTerm = useCallback((id: string) => {
    termHandlesRef.current.delete(id);
  }, []);

  /** Focus a terminal once its handle is registered. Defers via rAF so any
   *  reparent/render lands first, and retries a few frames so a just-mounted
   *  terminal (first restore / board create) is focusable too. */
  const focusTerm = (id: string) => {
    let tries = 0;
    const attempt = () => {
      const h = termHandlesRef.current.get(id);
      if (h) h.focus();
      else if (tries++ < 5) requestAnimationFrame(attempt);
    };
    requestAnimationFrame(attempt);
  };

  /** The live terminal on the active board that currently owns DOM keyboard focus
   *  (xterm's textarea lives inside the .term-host node, tagged with data-term-id),
   *  or undefined. Lets ⌥Tab/cycle start from the visibly-focused terminal even when
   *  the model prime is stale — clicking a terminal body focuses xterm without
   *  re-priming (Swift reconcilePrimeToFocus parity). */
  const focusedLiveTermId = (): string | undefined => {
    const hostEl = (document.activeElement as HTMLElement | null)?.closest?.(".term-host") as
      | HTMLElement
      | null;
    const id = hostEl?.dataset.termId;
    if (!id) return undefined;
    const c = activeBoard()?.cards.find((c) => c.kind === "term" && c.termId === id) as
      | TermCardModel
      | undefined;
    return c && c.live && !c.dead ? id : undefined;
  };

  // --- card factories ----------------------------------------------------------

  const makeTerm = (
    termId: string,
    frame: WorldFrame,
    z: number,
    opts: { needsSpawn: boolean; live?: boolean; prime?: boolean },
  ): TermCardModel => ({
    kind: "term",
    termId,
    frame,
    z,
    label: "shell",
    live: opts.live ?? true,
    dead: false,
    prime: opts.prime ?? false,
    bell: false,
    needsSpawn: opts.needsSpawn,
  });

  const unprime = (c: CardModel): CardModel =>
    c.kind === "term" && c.prime ? { ...c, prime: false } : c;

  /** Keep the live prime if it survives; else promote the first live terminal. */
  const reassignPrime = (cs: CardModel[]): CardModel[] => {
    const live = cs.filter((c) => c.kind === "term" && c.live && !c.dead) as TermCardModel[];
    const primeId = (live.find((c) => c.prime) ?? live[0])?.termId;
    return cs.map((c) =>
      c.kind === "term" ? { ...c, prime: c.live && !c.dead && c.termId === primeId } : c,
    );
  };

  // --- engine handoff ----------------------------------------------------------

  const onEngineReady = (boardId: string, engine: BoardEngine | null) => {
    if (engine) {
      enginesRef.current.set(boardId, engine);
      // If this is the active board, update the shortcut ref too.
      if (boardId === activeIdRef.current) engineRef.current = engine;
      // Seed the engine with the board's saved viewport if its restore already
      // arrived before the <Board> mounted (HMR replay, board_create auto-activate)
      // — applyRestore's setViewport was a no-op while this engine was still null.
      const b = boardsRef.current.get(boardId);
      if (b?.didRestore) engine.setViewport(b.viewport);
    } else {
      enginesRef.current.delete(boardId);
      if (boardId === activeIdRef.current) engineRef.current = null;
    }
  };

  // --- persistence (per-board, debounced) --------------------------------------

  const buildAndSendBoard = (boardId: string) => {
    const b = boardsRef.current.get(boardId);
    if (!b || !b.didRestore) return; // never overwrite saved layout pre-restore
    const terms = [];
    const docs = [];
    for (const c of b.cards) {
      if (c.kind === "term") terms.push({ termId: c.termId, frame: c.frame, z: c.z, dead: c.dead });
      else docs.push({ path: c.path, frame: c.frame, z: c.z, attached: c.attached });
    }
    const tiles = buildTiles(terms, docs, b.shelfPaths);
    const eng = enginesRef.current.get(boardId);
    const vp = eng?.viewport ?? b.viewport;
    void persistLayout(b.dockOrder, tiles, { zoom: vp.zoom, cx: vp.cx, cy: vp.cy }, boardId || null);
  };

  const schedulePersist = (boardId: string) => {
    const timers = persistTimers.current;
    const existing = timers.get(boardId);
    if (existing != null) clearTimeout(existing);
    timers.set(
      boardId,
      window.setTimeout(() => {
        timers.delete(boardId);
        buildAndSendBoard(boardId);
      }, PERSIST_DEBOUNCE_MS),
    );
  };

  const flushPersist = (boardId?: string) => {
    if (boardId !== undefined) {
      const timers = persistTimers.current;
      const existing = timers.get(boardId);
      if (existing == null) return;
      clearTimeout(existing);
      timers.delete(boardId);
      buildAndSendBoard(boardId);
    } else {
      // Flush all boards (blur / beforeunload).
      for (const [id] of persistTimers.current) flushPersist(id);
    }
  };

  // Persist whenever ANY board's card set or shelf changes (debounced). Each
  // mutation site calls schedulePersist(boardId) explicitly for targeted boards.
  // This effect catches the active board's React-batched mutations.
  useEffect(() => {
    schedulePersist(activeIdRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [boards]);

  /** Active-board viewport committed — persist (debounced) and coalesce the chrome
   * redraw onto one rAF so a wheel/pinch burst renders at most once per frame. */
  const onViewport = (boardId: string, vp: Viewport) => {
    if (boardId !== activeIdRef.current) return; // stale board callback — ignore
    schedulePersist(boardId);
    pendingVpRef.current = vp;
    if (vpRafRef.current != null) return;
    vpRafRef.current = requestAnimationFrame(() => {
      vpRafRef.current = null;
      if (pendingVpRef.current) setViewportState(pendingVpRef.current);
    });
  };

  // --- toasts ------------------------------------------------------------------

  const pushToast = (t: Omit<Toast, "expiresAtMs" | "id">) =>
    setToastState((s) => addToast(s, { ...t, id: mint() }, Date.now()));

  const onToastChip = (toastId: string, _chipIndex: number) =>
    setToastState((s) => dismissToast(s, toastId));

  useEffect(() => {
    if (toastState.toasts.length === 0) return;
    const id = window.setInterval(() => setToastState((s) => pruneExpired(s, Date.now())), TOAST_PRUNE_MS);
    return () => window.clearInterval(id);
  }, [toastState.toasts.length]);

  // --- doc content -------------------------------------------------------------

  const fetchDoc = async (path: string) => {
    try {
      const md = await readDoc(path);
      setDocContents((m) => new Map(m).set(path, md));
    } catch (e) {
      setDocContents((m) =>
        new Map(m).set(path, `*could not read ${path}*\n\n\`\`\`\n${String(e)}\n\`\`\``),
      );
    }
  };

  const refreshDoc = (path: string) => {
    // Refresh if any board has this doc open (file_event is path-only).
    for (const b of boardsRef.current.values()) {
      if (b.cards.some((c) => c.kind === "doc" && c.path === path)) {
        void fetchDoc(path);
        return;
      }
    }
  };

  /** Record a REAL file-change time (mtime) on every board that knows this doc, so the
   *  on-card + peek "✎ Ns" recency meta reflects the actual edit. Path-only, like file_event. */
  const stampDocChange = (path: string, mtimeMs: number) => {
    for (const [bid, b] of boardsRef.current) {
      if (!b.docMeta.has(path)) continue;
      setBoardState(bid, (bs) => {
        const prev = bs.docMeta.get(path);
        if (!prev) return bs;
        return { ...bs, docMeta: new Map(bs.docMeta).set(path, { ...prev, lastChangedMs: mtimeMs }) };
      });
    }
  };

  // --- doc landing (gravity placement) + shelf ---------------------------------

  const landDoc = (
    boardId: string,
    path: string,
    via: string,
    ownerTermId?: string,
    repoColor?: number,
    repo?: string,
    repoRoot?: string,
    lastChangedMs?: number,
  ) => {
    // Update per-board docMeta.
    setBoardState(boardId, (b) => {
      const prev = b.docMeta.get(path);
      const newMeta: DocMeta = {
        repoColor: repoColor ?? prev?.repoColor,
        ownerTermId: ownerTermId ?? prev?.ownerTermId,
        repo: repo ?? prev?.repo,
        repoRoot: repoRoot ?? prev?.repoRoot,
        lastChangedMs: lastChangedMs ?? prev?.lastChangedMs,
      };
      const newDocMeta = new Map(b.docMeta).set(path, newMeta);
      const newDockOrder = b.dockOrder.includes(path)
        ? b.dockOrder
        : [...b.dockOrder, path];
      // Remove from shelf if present.
      const newShelf = b.shelfPaths.filter((p) => p !== path);

      const onBoard = b.cards.find((c) => c.kind === "doc" && c.path === path);
      let newCards: CardModel[];
      if (onBoard) {
        // Re-open: refresh owner/color/fresh in place, never move.
        newCards = b.cards.map((c) =>
          c.kind === "doc" && c.path === path
            ? {
                ...c,
                ownerTermId: ownerTermId ?? c.ownerTermId,
                repoColor: repoColor ?? c.repoColor,
                fresh: via === "cli" ? true : c.fresh,
              }
            : c,
        );
      } else {
        const owner = ownerTermId
          ? (b.cards.find((c) => c.kind === "term" && c.termId === ownerTermId) as TermCardModel | undefined)
          : undefined;
        const prime = b.cards.find((c) => c.kind === "term" && c.prime) as TermCardModel | undefined;
        const anchor = owner?.frame ?? prime?.frame ?? BOOT_FRAME;
        const frame = firstFreeSlot(anchor, b.cards.map((c) => c.frame));
        const doc: DocCardModel = {
          kind: "doc",
          path,
          frame,
          z: topZ(b.cards) + 1,
          ownerTermId,
          repoColor,
          fresh: via === "cli",
          attached: ownerTermId != null,
        };
        newCards = [...b.cards, doc];
      }
      return { ...b, docMeta: newDocMeta, dockOrder: newDockOrder, shelfPaths: newShelf, cards: newCards };
    });
    // Persist THIS board (it may be a backgrounded board the [boards] effect's
    // active-board schedule would miss — e.g. `tarmac open` from a background term).
    schedulePersist(boardId);
    void fetchDoc(path);
  };

  const moveToShelf = (path: string) => {
    setActiveBoard((b) => ({
      ...b,
      cards: b.cards.filter((c) => !(c.kind === "doc" && c.path === path)),
      shelfPaths: b.shelfPaths.includes(path) ? b.shelfPaths : [...b.shelfPaths, path],
    }));
  };

  /** Bring a shelved doc back to the board at the drop point or next free slot. */
  const restoreFromShelf = (path: string, drop?: { clientX: number; clientY: number }) => {
    const b = activeBoard();
    const meta = b?.docMeta.get(path);
    let frame: WorldFrame;
    if (drop && engineRef.current) {
      const w = engineRef.current.viewToWorld(drop.clientX, drop.clientY);
      frame = { x: w.x - Place.docW / 2, y: w.y - 15, w: Place.docW, h: Place.docH };
    } else {
      const prime = b?.cards.find((c) => c.kind === "term" && c.prime) as TermCardModel | undefined;
      frame = firstFreeSlot(prime?.frame ?? BOOT_FRAME, b?.cards.map((c) => c.frame) ?? []);
    }
    setActiveBoard((board) => ({
      ...board,
      shelfPaths: board.shelfPaths.filter((p) => p !== path),
      cards: board.cards.some((c) => c.kind === "doc" && c.path === path)
        ? board.cards
        : [
            ...board.cards,
            {
              kind: "doc",
              path,
              frame,
              z: topZ(board.cards) + 1,
              ownerTermId: meta?.ownerTermId,
              repoColor: meta?.repoColor,
              fresh: false,
              attached: false,
            } as DocCardModel,
          ],
    }));
    void fetchDoc(path);
  };

  // --- peek (⌘P quick-look of the most-recent doc) ----------------------------

  const peekTarget = (): string | null => {
    const b = activeBoard();
    const meta = b?.docMeta;
    let best: string | null = null;
    let bestT = -Infinity;
    // Active-board scoped (Swift peeks the active board's store): only consider docs THIS
    // board knows, so the peeked path always resolves in its docMeta and ⌘⏎ never
    // fabricates a card from a cross-board path the active board has no meta for.
    for (const [p, t] of lastChangedRef.current) {
      if (meta?.has(p) && t > bestT) { bestT = t; best = p; }
    }
    if (best) return best;
    const order = b?.dockOrder ?? [];
    return order.length ? order[order.length - 1]! : null;
  };

  const openPeek = (explicitPath?: string) => {
    const target = explicitPath ?? peekTarget();
    if (!target) return;
    void fetchDoc(target);
    setPeekPath(target);
    setPeekVisible(true);
    setActiveCards((cs) =>
      cs.map((c) => (c.kind === "doc" && c.path === target ? { ...c, fresh: false } : c)),
    );
  };

  const togglePinPeeked = () => {
    const p = peekPathRef.current;
    if (!p) return;
    const b = activeBoard();
    if (b?.cards.some((c) => c.kind === "doc" && c.path === p)) moveToShelf(p);
    else if (b?.docMeta.has(p)) restoreFromShelf(p);
    // else: the peeked doc belongs to another board (a peek left open across a board
    // switch) — just dismiss; never fabricate a phantom meta-less card on this board.
    setPeekVisible(false);
  };

  // --- terminal lifecycle ------------------------------------------------------

  const spawnNewTerminal = (boardId?: string) => {
    const bid = boardId ?? activeIdRef.current;
    const b = boardsRef.current.get(bid);
    const existing = b?.cards ?? [];
    const prime = existing.find((c) => c.kind === "term" && c.prime) as TermCardModel | undefined;
    const base = prime?.frame ?? BOOT_FRAME;
    const origin = cascadeOrigin(
      { x: base.x, y: base.y },
      existing.map((c) => ({ x: c.frame.x, y: c.frame.y })),
      Place.cascadeDx,
      Place.cascadeDy,
    );
    const term = makeTerm(
      mint(),
      { x: origin.x, y: origin.y, w: Place.termFrame.w, h: Place.termFrame.h },
      topZ(existing) + 1,
      { needsSpawn: true, prime: true },
    );
    termBoardIndexRef.current.assign(term.termId, bid);
    setBoardCards(bid, (cs) => [...cs.map(unprime), term]);
  };

  const handleExit = (boardId: string, termId: string, code: number | null) => {
    const b = boardsRef.current.get(boardId);
    const term = b?.cards.find((c) => c.kind === "term" && c.termId === termId) as
      | TermCardModel | undefined;
    if (!term) return;
    // Clear dock if the exiting term was docked (avoid a phantom docked-but-dead pane).
    if (b?.dockedTermId === termId) setBoardState(boardId, (s) => ({ ...s, dockedTermId: null }));
    if (code !== 0) {
      pushToast({
        icon: "›_",
        title: code == null ? "killed by signal" : `shell exited · ${code}`,
        body: null,
        chips: [],
      });
    }
    const others = (b?.cards ?? []).filter(
      (c) => c.kind === "term" && c.termId !== termId && c.live && !c.dead,
    ).length;
    const action = decide(code, others);
    if (action === "holdOpen") {
      setBoardCards(boardId, (cs) =>
        reassignPrime(
          cs.map((c) =>
            c.kind === "term" && c.termId === termId
              ? { ...c, live: false, dead: true, prime: false }
              : c,
          ),
        ),
      );
    } else if (action === "remove") {
      setBoardCards(boardId, (cs) =>
        reassignPrime(cs.filter((c) => !(c.kind === "term" && c.termId === termId))),
      );
    } else {
      // removeAndReplace: keep ≥1 live terminal by spawning a fresh one in place.
      const { frame, z } = term;
      const fresh = makeTerm(mint(), frame, z, { needsSpawn: true, prime: true });
      termBoardIndexRef.current.assign(fresh.termId, boardId);
      setBoardCards(boardId, (cs) => [
        ...cs.filter((c) => !(c.kind === "term" && c.termId === termId)).map(unprime),
        fresh,
      ]);
    }
    // Remove from the index after handling.
    termBoardIndexRef.current.remove(termId);
    // Persist this board's new card set (it may be backgrounded).
    schedulePersist(boardId);
  };

  const onTermSpawn = (boardId: string, termId: string, cols: number, rows: number) => {
    const b = boardsRef.current.get(boardId);
    const term = b?.cards.find((c) => c.kind === "term" && c.termId === termId) as
      | TermCardModel | undefined;
    if (!term) return;
    if (term.needsSpawn) {
      void spawnTerm({ termId, cols, rows, boardId: boardId || undefined });
      setBoardCards(boardId, (cs) =>
        cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, needsSpawn: false } : c)),
      );
    } else {
      void termResize(termId, cols, rows);
    }
  };

  const applyTermProc = (boardId: string, termId: string, name: string) =>
    setBoardCards(boardId, (cs) =>
      cs.map((c) =>
        c.kind === "term" && c.termId === termId
          ? { ...c, label: displayLabel(undefined, name, "shell") }
          : c,
      ),
    );

  const onTermActivity = (termId: string) => {
    const boardId = termBoardIndexRef.current.board(termId) ?? activeIdRef.current;
    setBoardCards(boardId, (cs) => {
      if (!cs.some((c) => c.kind === "term" && c.termId === termId && c.bell)) return cs;
      bellTimeRef.current.delete(termId);
      return cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, bell: false } : c));
    });
  };

  // --- dock pane helpers (Wave 2) ----------------------------------------------

  /** Promote a specific term to prime on the active board and clear its bell. */
  const setPrimeTerm = (termId: string) =>
    setActiveCards((cs) =>
      cs.map((c) =>
        c.kind === "term"
          ? { ...c, prime: c.termId === termId, bell: c.termId === termId ? false : c.bell }
          : c,
      ),
    );

  const dockPrime = () => {
    const prime = activeBoard()?.cards.find(
      (c) => c.kind === "term" && c.prime && c.live && !c.dead,
    ) as TermCardModel | undefined;
    if (!prime) return;
    setBoardState(activeIdRef.current, (b) => ({ ...b, dockedTermId: prime.termId }));
    focusTerm(prime.termId);
  };

  const undockActive = () => {
    const id = activeBoard()?.dockedTermId;
    setBoardState(activeIdRef.current, (b) => ({ ...b, dockedTermId: null }));
    if (id) focusTerm(id); // return focus to the now-in-card terminal
  };

  const toggleDock = () => {
    activeBoard()?.dockedTermId != null ? undockActive() : dockPrime();
  };

  // --- cycle HUD + ⌥Tab handler (Wave 2) --------------------------------------

  const showCycleHud = (labels: string[], activeIndex: number) => {
    setCycleHud({ labels, activeIndex });
    if (cycleHudTimer.current != null) clearTimeout(cycleHudTimer.current);
    cycleHudTimer.current = window.setTimeout(() => setCycleHud(null), 1100);
  };

  const cycleTerminals = () => {
    if (activeBoard()?.dockedTermId != null) return; // parity: disabled while docked
    const cards = activeBoard()?.cards ?? [];
    const terms = cards.filter((c) => c.kind === "term") as TermCardModel[];
    const order = cycleOrder(
      terms.map((t) => ({ termId: t.termId, isLive: t.live && !t.dead })),
    );
    if (order.length === 0) return;
    // Reconcile to the visibly-focused terminal first (model prime may be stale if
    // the user clicked a terminal body without re-priming); else fall back to prime.
    const current = focusedLiveTermId() ?? terms.find((t) => t.prime)?.termId;
    const next = step(order, current, "next");
    if (!next) return;
    setPrimeTerm(next);
    focusTerm(next);
    // HUD: labels in cycle order, highlight the new prime.
    const labels = order.map((id) => terms.find((t) => t.termId === id)?.label ?? "shell");
    showCycleHud(labels, order.indexOf(next));
  };

  // --- restore (first visit: tiles + live_terms → cards; reconnect: reconcile) -

  const applyRestore = (msg: Extract<DaemonMsg, { t: "restore" }>) => {
    // Determine which board this restore targets.
    const boardId = msg.board_id ?? activeIdRef.current;

    // Ensure a slot exists for this board (daemon-pushed restore for an unvisited
    // board before we locally switch to it).
    setBoards((bs) => {
      if (bs.has(boardId)) return bs;
      const n = new Map(bs);
      n.set(boardId, emptyBoardState());
      return n;
    });

    const b = boardsRef.current.get(boardId);
    const isFirstVisit = !b?.didRestore;

    if (!isFirstVisit) {
      // RECONNECT REVIVE: the daemon restarted or we reconnected. Reconcile live
      // terms — mark any term the daemon no longer owns as dead.
      const live = new Set(msg.live_terms ?? []);
      const hadLive = b?.cards.some((c) => c.kind === "term" && c.live && !c.dead) ?? false;
      // Empty live_terms for a board that HAD live terms ⇒ a full daemon restart
      // (every pty across every board is gone). A transient socket blip where the
      // daemon survived re-sends the live_terms, so we keep those warm.
      const restart = live.size === 0 && hadLive;
      if (restart && !daemonRestartToastedRef.current) {
        daemonRestartToastedRef.current = true;
        pushToast({
          icon: "¶",
          title: "daemon restarted — terminals lost",
          body: "open new terminals with ⌘T",
          chips: [],
        });
      }
      // This board: keep daemon-owned terms warm, mark the rest dead. Drop a stale
      // dock latch if the docked term died (the daemon-restart path bypasses
      // handleExit, which is the other place dockedTermId is cleared) — else the raw
      // `dockedTermId != null` gates (⌥Tab/Esc/Return) misfire on an invisible latch.
      setBoardState(boardId, (board) => ({
        ...board,
        dockedTermId:
          board.dockedTermId != null && !live.has(board.dockedTermId) ? null : board.dockedTermId,
        cards: reassignPrime(
          board.cards.map((c) =>
            c.kind === "term" && !live.has(c.termId)
              ? { ...c, live: false, dead: true, prime: false }
              : c,
          ),
        ),
      }));
      // A full restart kills EVERY board's ptys, but the daemon only re-sends a
      // restore for the active board — so sweep every OTHER visited board's live
      // terminals to dead here (their warm cards would otherwise show zombie-live).
      if (restart) {
        for (const id of boardsRef.current.keys()) {
          if (id === boardId) continue;
          setBoardState(id, (board) => ({
            ...board,
            // A full restart kills every pty on every board → any dock latch is stale.
            dockedTermId: null,
            cards: reassignPrime(
              board.cards.map((c) =>
                c.kind === "term" && c.live && !c.dead
                  ? { ...c, live: false, dead: true, prime: false }
                  : c,
              ),
            ),
          }));
        }
      }
      return;
    }

    // FIRST VISIT: build cards from restore payload.
    const docs = msg.docs ?? [];
    const newDocMeta = new Map<string, DocMeta>();
    const newDockOrder: string[] = docs.map((d) => d.path);
    for (const d of docs) {
      newDocMeta.set(d.path, {
        repoColor: d.repo_color ?? undefined,
        ownerTermId: d.term_id ?? undefined,
        repo: d.repo ?? undefined,
        repoRoot: d.repo_root ?? undefined,
        lastChangedMs: d.last_changed_ms ?? undefined,
      });
    }

    const { termTiles, docTiles, shelfPaths: restoredShelf } = parseTiles(
      (msg.tiles ?? []) as unknown as LayoutTile[],
    );
    const liveTerms = new Set(msg.live_terms ?? []);

    const plans = plan(
      termTiles.map((t) => t.termId),
      liveTerms,
    );
    const oldToNew = new Map<string, string>();
    const newTerms: TermCardModel[] = termTiles.map((t, i) => {
      const frame =
        t.frame ?? {
          x: BOOT_FRAME.x + i * Place.cascadeDx,
          y: BOOT_FRAME.y + i * Place.cascadeDy,
          w: BOOT_FRAME.w,
          h: BOOT_FRAME.h,
        };
      const p = plans[i]!;
      if (p.kind === "rebind") {
        if (t.termId) oldToNew.set(t.termId, p.termId);
        // Register in index at rebind.
        termBoardIndexRef.current.assign(p.termId, boardId);
        return makeTerm(p.termId, frame, t.z, { needsSpawn: false });
      }
      const id = mint();
      if (t.termId) oldToNew.set(t.termId, id);
      // Register NOW (not in onTermSpawn, which is an async attach round-trip away)
      // so an exit/bell/term_proc frame arriving in the gap routes to THIS board,
      // not the active-board fallback (which would silently drop it).
      termBoardIndexRef.current.assign(id, boardId);
      return makeTerm(id, frame, t.z, { needsSpawn: true });
    });
    // Guarantee ≥1 terminal.
    if (newTerms.length === 0) {
      const id = mint();
      termBoardIndexRef.current.assign(id, boardId);
      newTerms.push(makeTerm(id, BOOT_FRAME, 0, { needsSpawn: true }));
    }
    newTerms[0]!.prime = true;

    let scatterSlot = 0;
    const newDocs: DocCardModel[] = [];
    for (const dt of docTiles) {
      if (!newDocMeta.has(dt.path)) {
        console.warn(`restore: doc tile ${dt.path} absent from the registry — dropping`);
        continue;
      }
      const meta = newDocMeta.get(dt.path)!;
      const owner = meta.ownerTermId ? oldToNew.get(meta.ownerTermId) : undefined;
      newDocs.push({
        kind: "doc",
        path: dt.path,
        frame: dt.frame ?? scatterFrame(scatterSlot++),
        z: dt.z,
        ownerTermId: owner,
        repoColor: meta.repoColor,
        fresh: false,
        attached: dt.attached && owner !== undefined,
      });
      void fetchDoc(dt.path);
    }

    const vp = msg.board
      ? { zoom: msg.board.zoom, cx: msg.board.cx, cy: msg.board.cy }
      : { zoom: 1, cx: 0, cy: 0 };

    setBoardState(boardId, (_) => ({
      cards: [...newTerms, ...newDocs],
      shelfPaths: restoredShelf.filter((p) => newDocMeta.has(p)),
      dockOrder: newDockOrder,
      docMeta: newDocMeta,
      viewport: vp,
      didRestore: true,
      dockedTermId: null,
    }));

    // Defensive: if a REAL board's restore arrives while we're still on the
    // synthetic seed (restore-before-board_list ordering), adopt it as active so
    // its boot terminal isn't stranded on a hidden board, and retire the seed.
    if (activeIdRef.current === SYNTHETIC_ID && boardId !== SYNTHETIC_ID) {
      const syn = boardsRef.current.get(SYNTHETIC_ID);
      activeIdRef.current = boardId;
      setActiveBoardId(boardId);
      engineRef.current = enginesRef.current.get(boardId) ?? null;
      if (syn && !syn.didRestore && syn.cards.length === 0) {
        setBoards((bs) => {
          const n = new Map(bs);
          n.delete(SYNTHETIC_ID);
          return n;
        });
      }
    }

    // Apply viewport to the engine if this is the active board.
    if (boardId === activeIdRef.current) {
      const eng = enginesRef.current.get(boardId);
      eng?.setViewport(vp);
      // First visit of the active board (boot / ⌘N create / switch-to-new): focus its
      // prime terminal so the user can type immediately (focusTerm retries until the
      // just-mounted terminal registers its handle).
      const p = newTerms[0];
      if (p && p.live && !p.dead) focusTerm(p.termId);
    }
  };

  // --- board switch machine ----------------------------------------------------

  const closeSwitcher = () => {
    setSwitcherOpen(false);
    setSwitcherFilter("");
    setSwitcherSelected(0);
    setSwitcherEditing(false);
    setSwitcherEditBuffer("");
    setSwitcherConfirming(false);
  };

  const beginSwitchTo = (targetId: string, fromDaemon: boolean) => {
    const currentId = activeIdRef.current;
    if (targetId === currentId) {
      closeSwitcher();
      return;
    }
    // Flush the current board's pending persist.
    flushPersist(currentId);

    // Ensure a slot exists for the target, and retire the synthetic pre-restore
    // board once we leave it for a real one (it never received content, so it has
    // no didRestore and no cards — it must not linger as an empty hidden board).
    setBoards((bs) => {
      const n = new Map(bs);
      if (!n.has(targetId)) n.set(targetId, emptyBoardState());
      const syn = n.get(SYNTHETIC_ID);
      if (
        currentId === SYNTHETIC_ID &&
        targetId !== SYNTHETIC_ID &&
        syn &&
        !syn.didRestore &&
        syn.cards.length === 0
      ) {
        n.delete(SYNTHETIC_ID);
      }
      return n;
    });

    // Update active board id + ref synchronously.
    activeIdRef.current = targetId;
    setActiveBoardId(targetId);

    // Update the active engine ref.
    engineRef.current = enginesRef.current.get(targetId) ?? null;

    // If the switch was initiated locally (user pressed ⏎ or ⌘N etc.), tell the
    // daemon. The daemon will reply with board_list + restore for the target board.
    if (!fromDaemon) {
      void boardSwitch(targetId);
    }

    // The target board's engine keeps its LIVE viewport across display:none (warm
    // hosting) — do NOT reset it to the frozen restore snapshot (that would discard
    // pans/zooms made earlier this session). Just sync the chrome readout to the
    // engine's current viewport. (A never-mounted engine is seeded in onEngineReady.)
    const eng = enginesRef.current.get(targetId);
    if (eng) setViewportState(eng.viewport);

    // Re-establish keyboard focus on the arrived board (Swift parity: finishArrive).
    // The previously-focused terminal was blurred when its board went display:none,
    // so without this, post-switch keystrokes go nowhere until the user clicks.
    // Prefer a live re-docked terminal, else the arrived board's live prime.
    const arrived = boardsRef.current.get(targetId);
    const dockedLiveId =
      arrived?.dockedTermId &&
      arrived.cards.some(
        (c) => c.kind === "term" && c.termId === arrived.dockedTermId && c.live && !c.dead,
      )
        ? arrived.dockedTermId
        : undefined;
    const arrivedPrime = (arrived?.cards.find(
      (c) => c.kind === "term" && c.prime && c.live && !c.dead,
    ) as TermCardModel | undefined)?.termId;
    const focusId = dockedLiveId ?? arrivedPrime;
    if (focusId) focusTerm(focusId);

    closeSwitcher();
    setSelectedId(null);
  };

  // --- ⌘K switcher: build rows -------------------------------------------------

  /** Per-board summaries from local card state + daemon metas. */
  const buildSummaries = (): BoardSummary[] => {
    const bs = boardsRef.current;
    const metas = boardMetasRef.current;

    // If we have metas from board_list, use those as the canonical order.
    // Otherwise synthesize from local boards.
    const ids: string[] =
      metas.length > 0
        ? metas.map((m) => m.board_id)
        : Array.from(bs.keys());

    return ids.map((id) => {
      const meta = metas.find((m) => m.board_id === id);
      const board = bs.get(id);
      const visited = board?.didRestore ?? false;
      const localRunning = board?.cards.filter(
        (c) => c.kind === "term" && c.live && !c.dead,
      ).length ?? 0;
      const localBell = board?.cards.filter(
        (c) => c.kind === "term" && c.bell,
      ).length ?? 0;
      const localIsLive = localRunning > 0;
      const { running, isLive } = liveness(
        visited,
        localRunning,
        localIsLive,
        meta?.running ?? null,
      );
      return {
        boardID: id,
        name: meta?.name ?? null,
        running,
        bell: localBell,
        cards: board?.cards.length ?? 0,
        isLive,
      };
    });
  };

  // Build the visible rows for the current filter — used both for render and for
  // key-handler ordinal lookups (must be the same list).
  const currentSwitcherRows = (): BoardRow[] =>
    switcherRows(buildSummaries(), activeIdRef.current, switcherFilterRef.current);

  // --- daemon-frame routing helpers --------------------------------------------

  const routeBoardId = (termId: string): string =>
    termBoardIndexRef.current.board(termId) ?? activeIdRef.current;

  // --- daemon stream -----------------------------------------------------------

  const handle = (msg: DaemonMsg) => {
    switch (msg.t) {
      case "restore":
        applyRestore(msg);
        break;

      case "board_list": {
        setBoardMetas(msg.boards);
        // If the daemon reports a different active board (e.g. after board_create
        // auto-activates), adopt it as a daemon-initiated switch FIRST so activeId
        // is current before the prune below.
        if (msg.active && msg.active !== activeIdRef.current) {
          beginSwitchTo(msg.active, /*fromDaemon*/ true);
        }
        // Prune local state for boards the daemon no longer has (deleted elsewhere
        // or via ⌘⌫): drop the BoardState (unmounts its <Board> → engine.destroy),
        // its term-index entries, and any pending persist timer. Never prune the
        // synthetic seed or the active board.
        const ids = new Set(msg.boards.map((m) => m.board_id));
        setBoards((bs) => {
          let changed = false;
          const n = new Map(bs);
          for (const id of bs.keys()) {
            if (id === SYNTHETIC_ID || id === activeIdRef.current || ids.has(id)) continue;
            n.delete(id);
            termBoardIndexRef.current.removeBoard(id);
            const t = persistTimers.current.get(id);
            if (t != null) {
              clearTimeout(t);
              persistTimers.current.delete(id);
            }
            changed = true;
          }
          return changed ? n : bs;
        });
        break;
      }

      case "doc_opened": {
        // A doc with no owner term (user-opened) lands on the ACTIVE board; with an
        // owner, route to that term's board. Never index-lookup the empty string
        // (it could resolve to a stale synthetic-board entry).
        const boardId = msg.term_id ? routeBoardId(msg.term_id) : activeIdRef.current;
        lastChangedRef.current.set(msg.path, Date.now()); // (unchanged — feeds peekTarget order)
        landDoc(
          boardId, msg.path, msg.via,
          msg.term_id ?? undefined,
          msg.repo_color ?? undefined,
          msg.repo ?? undefined,
          msg.repo_root ?? undefined,
          msg.last_changed_ms ?? undefined,
        );
        break;
      }

      case "file_event":
        lastChangedRef.current.set(msg.path, Date.now()); // (unchanged — peekTarget order)
        stampDocChange(msg.path, msg.mtime_ms);           // NEW — real edit time for recency
        refreshDoc(msg.path);
        break;

      case "exit": {
        const boardId = routeBoardId(msg.term_id);
        handleExit(boardId, msg.term_id, msg.code ?? null);
        break;
      }

      case "term_proc": {
        const boardId = routeBoardId(msg.term_id);
        applyTermProc(boardId, msg.term_id, msg.name);
        break;
      }

      case "bell": {
        const boardId = routeBoardId(msg.term_id);
        bellTimeRef.current.set(msg.term_id, Date.now());
        setBoardCards(boardId, (cs) =>
          cs.map((c) => (c.kind === "term" && c.termId === msg.term_id ? { ...c, bell: true } : c)),
        );
        break;
      }

      default:
        break; // hello_ok / err / unknown — ignored
    }
  };

  const handleStatus = (s: DaemonStatus) => {
    setStatus(s);
    if (prevConnectedRef.current && !s.connected) {
      // New disconnect → re-arm the restart toast for the next reconnect cycle.
      daemonRestartToastedRef.current = false;
      pushToast({ icon: "¶", title: "tarmacd connection lost", body: s.reason ?? null, chips: [] });
    }
    prevConnectedRef.current = s.connected;
  };

  // --- global key handler ------------------------------------------------------

  useEffect(() => {
    const subs = [onDaemonStatus(handleStatus), onDaemonMsg(handle)];
    void Promise.all(subs).then(frontendReady);

    const onKeyDown = (e: KeyboardEvent) => {
      if (isComposingKey(e)) return;
      // ⌘K — toggle the board switcher (highest priority).
      if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "k") {
        e.preventDefault();
        e.stopPropagation();
        if (switcherOpenRef.current) {
          closeSwitcher();
        } else {
          setSwitcherOpen(true);
          setSwitcherSelected(
            Math.max(0, currentSwitcherRows().findIndex((r) => r.isActive)),
          );
        }
        return;
      }

      // --- switcher-owned key handling -----------------------------------------
      if (switcherOpenRef.current) {
        // The switcher owns the keyboard while open. This handler runs in CAPTURE
        // phase (below), so stopping propagation here keeps the focused terminal's
        // xterm from also receiving the keystroke (it would otherwise type filter
        // chars into the prime PTY). Only ⌘Q / ⌘W fall through to the menus.
        const passThrough = e.metaKey && (e.key.toLowerCase() === "q" || e.key.toLowerCase() === "w");
        if (!passThrough) e.stopPropagation();
        const rows = currentSwitcherRows();
        const sel = switcherSelectedRef.current;
        const editing = switcherEditingRef.current;
        const confirming = switcherConfirmingRef.current;

        // Escape: cancel rename → disarm confirm → close.
        if (e.key === "Escape") {
          e.preventDefault();
          if (editing) { setSwitcherEditing(false); setSwitcherEditBuffer(""); return; }
          if (confirming) { setSwitcherConfirming(false); return; }
          closeSwitcher();
          return;
        }

        // ⌘E — begin inline rename (seed buffer from selected row display name).
        if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "e") {
          e.preventDefault();
          const row = rows[sel];
          if (row) {
            setSwitcherEditing(true);
            setSwitcherEditBuffer(row.display);
            setSwitcherConfirming(false);
          }
          return;
        }

        // ⌘Backspace — delete (arm confirm / second press executes).
        if (e.metaKey && e.key === "Backspace") {
          e.preventDefault();
          if (editing) return; // don't delete while renaming
          const row = rows[sel];
          // canDelete is about TOTAL boards (the daemon refuses the last one), not
          // the filtered row count — a 1-row filter must not block delete.
          if (!row || !canDelete(Math.max(boardMetasRef.current.length, boardsRef.current.size))) return;
          if (confirming) {
            // Second ⌘⌫ — execute delete.
            void boardDelete(row.boardID);
            setSwitcherConfirming(false);
            closeSwitcher();
          } else {
            setSwitcherConfirming(true);
          }
          return;
        }

        // Enter — commit rename OR switch to selected.
        if (e.key === "Enter" && !e.metaKey) {
          e.preventDefault();
          if (editing) {
            const row = rows[sel];
            if (row) {
              const name = sanitizedName(switcherEditBufferRef.current);
              void boardRename(row.boardID, name);
            }
            setSwitcherEditing(false);
            setSwitcherEditBuffer("");
          } else {
            const row = rows[sel];
            if (row) beginSwitchTo(row.boardID, /*fromDaemon*/ false);
          }
          return;
        }

        // ArrowUp / ArrowDown — move selection (no wrap; clamp). Any non-⌘⌫ key
        // disarms a pending delete-confirm (Swift parity) so the second ⌘⌫ can't
        // land on a different row than the one the user confirmed.
        if (e.key === "ArrowUp" || e.key === "ArrowDown") {
          e.preventDefault();
          if (confirming) setSwitcherConfirming(false);
          const next = sel + (e.key === "ArrowUp" ? -1 : 1);
          setSwitcherSelected(clampSelection(next, rows.length));
          return;
        }

        // Backspace (no meta) — trim editBuffer if editing, else trim filter.
        if (e.key === "Backspace" && !e.metaKey && !e.altKey && !e.ctrlKey) {
          e.preventDefault();
          if (confirming) setSwitcherConfirming(false);
          if (editing) {
            setSwitcherEditBuffer((b) => b.slice(0, -1));
          } else {
            setSwitcherFilter((f) => {
              const next = f.slice(0, -1);
              switcherFilterRef.current = next;
              const nr = switcherRows(buildSummaries(), activeIdRef.current, next);
              setSwitcherSelected(clampSelection(switcherSelectedRef.current, nr.length));
              return next;
            });
          }
          return;
        }

        // ⌘1–9 — ordinal switch.
        if (e.metaKey && !e.altKey && !e.ctrlKey && e.key >= "1" && e.key <= "9") {
          e.preventDefault();
          const n = parseInt(e.key, 10);
          const id = boardIdForOrdinal(n, rows);
          if (id) beginSwitchTo(id, /*fromDaemon*/ false);
          return;
        }

        // ⌘N — create a new board (daemon mints + auto-activates via board_list).
        if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "n") {
          e.preventDefault();
          void boardCreate();
          closeSwitcher();
          return;
        }

        // Printable character — append to editBuffer (rename) or filter.
        if (
          e.key.length === 1 &&
          !e.metaKey && !e.ctrlKey && !e.altKey &&
          isTypable(e.key.codePointAt(0) ?? 0)
        ) {
          e.preventDefault();
          if (confirming) setSwitcherConfirming(false);
          if (editing) {
            setSwitcherEditBuffer((b) => b + e.key);
          } else {
            setSwitcherFilter((f) => {
              const next = f + e.key;
              switcherFilterRef.current = next;
              const nr = switcherRows(buildSummaries(), activeIdRef.current, next);
              setSwitcherSelected(clampSelection(0, nr.length));
              return next;
            });
          }
          return;
        }

        // Swallow everything else while the switcher is open (except ⌘Q / ⌘W).
        if (!(e.metaKey && (e.key === "q" || e.key === "Q" || e.key === "w" || e.key === "W"))) {
          e.preventDefault();
        }
        return;
      }

      // --- board-level shortcuts (switcher closed) ------------------------------

      // ⌥Tab — cycle prime terminal forward (Wave 2). Capture phase + stopPropagation
      // takes Tab from xterm and prevents browser focus traversal.
      if (e.altKey && !e.metaKey && !e.ctrlKey && !e.shiftKey && e.code === "Tab") {
        e.preventDefault();
        e.stopPropagation();
        cycleTerminals(); // itself a no-op while docked
        return;
      }

      // ⌘T — new terminal on the active board.
      if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "t") {
        e.preventDefault();
        spawnNewTerminal();
        return;
      }
      // ⌘P — peek the most-recent doc.
      if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "p") {
        e.preventDefault();
        openPeek();
        return;
      }
      // ⌘⏎ — pin / unpin the peeked doc.
      if (e.metaKey && e.key === "Enter") {
        if (peekVisibleRef.current) {
          e.preventDefault();
          togglePinPeeked();
        }
        return;
      }
      // ⏎ — fly to the highest-priority offscreen signal; fall through to dock toggle
      // when no offscreen signal is pending (Swift parity: fly-to-signal wins over dock).
      if (e.key === "Enter" && !e.metaKey && !e.altKey && !e.ctrlKey) {
        const active = document.activeElement as HTMLElement | null;
        if (active?.closest?.(".term-host, button, input, textarea, [contenteditable]")) return;
        const target = flyTargetRef.current;
        if (target && engineRef.current) {
          const card = activeBoard()?.cards.find((c) => cardId(c) === target);
          if (card) {
            preFlightRef.current = engineRef.current.viewport;
            engineRef.current.flyToCard(card.frame);
            e.preventDefault();
          }
          return;
        }
        // No offscreen signal pending → bare Return toggles the dock (Wave 2).
        e.preventDefault();
        toggleDock();
        return;
      }
      // ESC ladder: undock → peek → toasts → fly-back → fresh-doc-to-shelf. Each
      // consuming branch stopPropagation()s so the ESC does NOT also reach the
      // focused xterm (capture phase runs before it). Only the final fall-through
      // (no overlay) lets ESC reach the terminal.
      if (e.key === "Escape") {
        // Undock first (Wave 2) — consume so the docked terminal doesn't receive Esc.
        if (activeBoard()?.dockedTermId != null) {
          e.preventDefault();
          e.stopPropagation();
          undockActive();
          return;
        }
        if (peekVisibleRef.current) {
          e.preventDefault();
          e.stopPropagation();
          setPeekVisible(false);
          return;
        }
        if (toastsRef.current.length > 0) {
          e.preventDefault();
          e.stopPropagation();
          setToastState((s) => clearAllToasts(s));
          return;
        }
        if (preFlightRef.current && engineRef.current) {
          e.preventDefault();
          e.stopPropagation();
          engineRef.current.flyTo(preFlightRef.current);
          preFlightRef.current = null;
          return;
        }
        const b = activeBoard();
        const fresh = b?.cards.find((c) => c.kind === "doc" && c.fresh) as DocCardModel | undefined;
        if (fresh) {
          e.preventDefault();
          e.stopPropagation();
          moveToShelf(fresh.path);
        }
      }
    };

    // Capture phase: the window handler must run BEFORE the focused xterm so the
    // switcher (and the board shortcuts) can intercept keys. Closed-switcher paths
    // never stopPropagation, so ESC/⏎ still reach the terminal exactly as before.
    const onFlush = () => flushPersist();
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("blur", onFlush);
    window.addEventListener("beforeunload", onFlush);

    return () => {
      subs.forEach((p) => void p.then((off) => off()));
      window.removeEventListener("keydown", onKeyDown, true);
      window.removeEventListener("blur", onFlush);
      window.removeEventListener("beforeunload", onFlush);
      if (vpRafRef.current != null) cancelAnimationFrame(vpRafRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- card gestures -----------------------------------------------------------

  const onCardMoveStart = (id: string) => {
    const b = activeBoard();
    const card = b?.cards.find((c) => cardId(c) === id);
    if (!card) return;
    if (card.kind === "term") {
      const sats = new Map<string, WorldFrame>();
      for (const c of b?.cards ?? []) {
        if (c.kind === "doc" && c.attached && c.ownerTermId === card.termId) {
          sats.set(c.path, { ...c.frame });
        }
      }
      gestureRef.current = { kind: "term", termId: card.termId, startFrame: { ...card.frame }, sats };
    } else {
      gestureRef.current = { kind: "doc", path: card.path };
    }
  };

  const onCardMove = (id: string, frame: WorldFrame) => {
    const g = gestureRef.current;
    if (g && g.kind === "term" && `term:${g.termId}` === id) {
      const dx = frame.x - g.startFrame.x;
      const dy = frame.y - g.startFrame.y;
      setActiveCards((cs) =>
        cs.map((c) => {
          if (c.kind === "term" && c.termId === g.termId) return { ...c, frame };
          if (c.kind === "doc" && g.sats.has(c.path)) {
            const s = g.sats.get(c.path)!;
            return { ...c, frame: { ...c.frame, x: s.x + dx, y: s.y + dy } };
          }
          return c;
        }),
      );
    } else {
      setActiveCards((cs) => cs.map((c) => (cardId(c) === id ? ({ ...c, frame } as CardModel) : c)));
    }
  };

  const onCardMoveEnd = (id: string) => {
    const g = gestureRef.current;
    gestureRef.current = null;
    if (g && g.kind === "doc" && `doc:${g.path}` === id) {
      setActiveCards((cs) =>
        cs.map((c) =>
          c.kind === "doc" && c.path === g.path ? { ...c, attached: false, fresh: false } : c,
        ),
      );
    }
  };

  const onCardResize = (id: string, frame: WorldFrame) =>
    setActiveCards((cs) => cs.map((c) => (cardId(c) === id ? ({ ...c, frame } as CardModel) : c)));

  const onCardResizeEnd = (_id: string) => {};

  const onCardGrab = (id: string) => {
    setSelectedId(id);
    setActiveCards((cs) => {
      const target = cs.find((c) => cardId(c) === id);
      if (!target) return cs;
      const top = topZ(cs) + 1;
      const makesPrime = target.kind === "term" && target.live && !target.dead;
      return cs.map((c) => {
        let nc: CardModel = cardId(c) === id ? { ...c, z: top } : c;
        if (makesPrime && nc.kind === "term") {
          const isThis = nc.termId === (target as TermCardModel).termId;
          nc = { ...nc, prime: isThis, bell: isThis ? false : nc.bell };
        }
        return nc;
      });
    });
  };

  const onMinimapJump = (world: { x: number; y: number }) => {
    const engine = engineRef.current;
    if (!engine) return;
    const vp = engine.viewport;
    engine.setViewport({ zoom: vp.zoom, cx: world.x, cy: world.y });
  };

  // --- TermBoardIndex: register new needsSpawn terms on first render -----------
  // When applyRestore creates cards with needsSpawn:true, onTermSpawn fires later
  // when the terminal measures itself. We register them in the index then. For
  // rebind cards (needsSpawn:false) we register in applyRestore directly.
  // Cold-spawn cards are registered in onTermSpawn (below in the closure we pass
  // to Board).

  // --- offscreen hints + minimap -----------------------------------------------

  const hhmmFor = (c: CardModel): string =>
    c.kind === "term" ? formatClock(bellTimeRef.current.get(c.termId) ?? Date.now()) : formatClock(Date.now());

  const activeCards = activeBoard()?.cards ?? [];

  const offscreen = useMemo<{ pills: PlacedPill[]; flyTarget: string | null }>(() => {
    const engine = engineRef.current;
    if (!engine) return { pills: [], flyTarget: null };
    const wr = engine.viewportWorldRect;
    const size = engine.viewportSize;
    const hints: OffscreenHint[] = [];
    for (const c of activeCards) {
      const sig = cardSignal(c);
      if (!sig) continue;
      const cx = c.frame.x + c.frame.w / 2;
      const cy = c.frame.y + c.frame.h / 2;
      if (!isOffscreen({ x: cx, y: cy }, wr)) continue;
      hints.push({
        cardId: cardId(c),
        centerView: engine.worldToLocal(cx, cy),
        signal: sig,
        label: pillLabel(sig, c.kind === "term" ? c.label : basename(c.path), hhmmFor(c)),
        z: c.z,
      });
    }
    const pills = stackPills(hints, { x: 0, y: 0, w: size.w, h: size.h }, {
      edgeInset: HINT_EDGE_INSET,
      edgeMargin: HINT_EDGE_MARGIN,
      stackGap: HINT_STACK_GAP,
      pillSize: measurePill,
    });
    return { pills, flyTarget: selectFlyTarget(hints) };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeCards, viewport]);
  flyTargetRef.current = offscreen.flyTarget;

  const engine = engineRef.current;
  const minimapItems: MinimapItem[] = activeCards.map((c) => ({
    worldRect: c.frame,
    signal: (cardSignal(c) ?? "none") as MinimapSignal,
  }));
  const viewportWorldRect = engine ? engine.viewportWorldRect : { x: 0, y: 0, w: 0, h: 0 };

  // Active board's shelf + meta (for chrome).
  const activeShelf = activeBoard()?.shelfPaths ?? [];
  const activeDocMeta = activeBoard()?.docMeta ?? new Map<string, DocMeta>();
  // Peek chrome resolves from the board that OWNS the doc (active first, then any board)
  // so an open peek keeps its header (repo-path / dot / recency) stable across a board
  // switch instead of blanking against the new active board's docMeta.
  const docMetaFor = (path: string): DocMeta | undefined => {
    const active = activeDocMeta.get(path);
    if (active) return active;
    for (const bs of boards.values()) {
      const m = bs.docMeta.get(path);
      if (m) return m;
    }
    return undefined;
  };
  const peekMeta = peekPath ? docMetaFor(peekPath) : undefined;
  const activePeekColor = peekMeta?.repoColor;
  const peekDisplayPath = peekPath
    ? docDisplayPath(peekPath, peekMeta?.repo, peekMeta?.repoRoot)
    : "";

  // --- dock pane derived state (Wave 2) ----------------------------------------
  const activeDockedTermId = activeBoard()?.dockedTermId ?? null;
  // Pane is visible only when the docked term is live + present on the active board.
  const dockedLive =
    activeDockedTermId != null &&
    activeCards.some(
      (c) => c.kind === "term" && c.termId === activeDockedTermId && c.live && !c.dead,
    );
  const dockLabel =
    (activeCards.find((c) => c.kind === "term" && c.termId === activeDockedTermId) as TermCardModel | undefined)
      ?.label ?? "shell";

  const dockCtx = useMemo<DockContextValue>(
    () => ({
      dockedTermId: dockedLive ? activeDockedTermId : null,
      dockSlot,
      registerTerm,
      unregisterTerm,
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [dockedLive, activeDockedTermId, dockSlot, registerTerm, unregisterTerm],
  );

  // Switcher rows (computed fresh each render; also used in keydown via
  // currentSwitcherRows() which re-derives from the same buildSummaries).
  const renderedSwitcherRows: BoardRow[] = switcherOpen
    ? switcherRows(buildSummaries(), activeBoardId, switcherFilter)
    : [];
  const switcherDeleteTarget =
    switcherConfirming && switcherSelected < renderedSwitcherRows.length
      ? renderedSwitcherRows[switcherSelected]?.display ?? null
      : null;

  // The active board's per-board engine ref: App maps over boards and binds
  // boardId into each callback. We need a stable enginesRef per board for the
  // per-board <Board> engineRef prop (Board writes to it on mount).
  // We use a per-board MutableRefObject stored in a ref-of-map.
  const boardEngineRefsRef = useRef<Map<string, React.MutableRefObject<BoardEngine | null>>>(new Map());
  const getBoardEngineRef = (boardId: string): React.MutableRefObject<BoardEngine | null> => {
    if (!boardEngineRefsRef.current.has(boardId)) {
      boardEngineRefsRef.current.set(boardId, { current: null });
    }
    return boardEngineRefsRef.current.get(boardId)!;
  };

  // The boards to render: every board we have local state for. We iterate the
  // boards Map (insertion order = visit order).
  const boardEntries = Array.from(boards.entries());

  return (
    <div className="app">
      <div className="board-stack">
        <DockContext.Provider value={dockCtx}>
        {boardEntries.map(([bid, boardState]) => {
          const hidden = bid !== activeBoardId;
          const perBoardEngineRef = getBoardEngineRef(bid);
          return (
            <Board
              key={bid}
              boardId={bid}
              hidden={hidden}
              onEngineReady={onEngineReady}
              cards={boardState.cards}
              docContents={docContents}
              docMeta={boardState.docMeta}
              engineRef={perBoardEngineRef}
              onViewport={(vp) => onViewport(bid, vp)}
              onCardMove={onCardMove}
              onCardMoveStart={onCardMoveStart}
              onCardMoveEnd={onCardMoveEnd}
              onCardResize={onCardResize}
              onCardResizeEnd={onCardResizeEnd}
              onCardGrab={onCardGrab}
              onTermSpawn={(termId, cols, rows) => {
                // Register term in index on spawn (covers cold-spawn cards).
                termBoardIndexRef.current.assign(termId, bid);
                onTermSpawn(bid, termId, cols, rows);
              }}
              onTermTitle={(termId, title) =>
                title.trim()
                  ? setBoardCards(bid, (cs) =>
                      cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, label: title } : c)),
                    )
                  : undefined
              }
              onTermActivity={onTermActivity}
              onDocClose={moveToShelf}
              selectedId={hidden ? null : selectedId}
              onBackgroundPointerDown={() => { if (!hidden) setSelectedId(null); }}
            />
          );
        })}
        <TitleBarChip name={boardChipLabel(null, "tarmac")} attached={status.connected} />
        <ShelfOverlay
          paths={activeShelf}
          repoColorFor={(p) => activeDocMeta.get(p)?.repoColor}
          onPeek={(p) => openPeek(p)}
          onRestore={restoreFromShelf}
        />
        <ZoomControl
          zoom={viewport.zoom}
          onZoomIn={() => engineRef.current?.zoomByCentered(ZOOM_STEP)}
          onZoomOut={() => engineRef.current?.zoomByCentered(1 / ZOOM_STEP)}
          onFit={() => engineRef.current?.fitToCards()}
        />
        <MinimapOverlay items={minimapItems} viewportWorldRect={viewportWorldRect} onJump={onMinimapJump} />
        <OffscreenHints pills={offscreen.pills} />
        <PeekOverlay
          visible={peekVisible}
          path={peekPath}
          displayPath={peekDisplayPath}
          markdown={peekPath ? docContents.get(peekPath) ?? "" : ""}
          repoColor={activePeekColor}
          lastChangedMs={peekMeta?.lastChangedMs}
          onPin={togglePinPeeked}
          onClose={() => setPeekVisible(false)}
        />
        <ToastOverlay toasts={toastState.toasts} onChipClick={onToastChip} />
        {/* ⌘K board switcher — rendered only when open (the veil + panel are portaled
            inside the board-stack so the z-index ordering is local to it). */}
        <BoardSwitcher
          visible={switcherOpen}
          rows={renderedSwitcherRows}
          selected={switcherSelected}
          query={switcherFilter}
          editing={switcherEditing}
          editBuffer={switcherEditBuffer}
          confirmingDelete={switcherConfirming}
          deleteTarget={switcherDeleteTarget}
          onDismiss={closeSwitcher}
          onPickRow={(i) => {
            const row = renderedSwitcherRows[i];
            if (row) beginSwitchTo(row.boardID, /*fromDaemon*/ false);
          }}
        />
        <CycleHud hud={cycleHud} />
        </DockContext.Provider>
        <DockPane visible={dockedLive} label={dockLabel} bodyRef={setDockSlot} />
      </div>
      <StatusBar connected={status.connected} reason={status.reason} cards={activeCards.length} />
    </div>
  );
}
