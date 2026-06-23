// The cockpit orchestrator: subscribes to the daemon stream, owns the board's
// card set, runs the multi-terminal lifecycle (boot/⌘T/exit/prime), lands
// `tarmac open` docs with gravity placement + a provenance edge, parks docs on a
// shelf, and round-trips the whole layout (tiles + viewport) to the daemon so a
// board survives a restart. Phase 4 adds the wayfinding + feedback chrome:
// zoom control, minimap, offscreen-signal hints (+ ⏎ fly / Esc fly-back), the ⌘P
// peek slide-over, transient toasts, the session chip, and full card-chrome
// states (selection ring, resize handles, quiet/detached). This is
// AppController.swift's whiteboard core minus the multi-board switcher (Phase 5).

import { useEffect, useMemo, useRef, useState } from "react";
import { Board } from "./board/Board";
import { StatusBar } from "./ui/StatusBar";
import { ShelfOverlay } from "./ui/ShelfOverlay";
import { ZoomControl } from "./ui/ZoomControl";
import { MinimapOverlay, type MinimapItem, type MinimapSignal } from "./ui/MinimapOverlay";
import { OffscreenHints } from "./ui/OffscreenHints";
import { PeekOverlay } from "./ui/PeekOverlay";
import { ToastOverlay } from "./ui/ToastOverlay";
import { TitleBarChip } from "./ui/TitleBarChip";
import type { BoardEngine, Viewport } from "./board/BoardEngine";
import {
  cardId,
  topZ,
  type CardModel,
  type DocCardModel,
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
} from "./ipc/daemon";
import type { DaemonMsg, DaemonStatus } from "./ipc/protocol";

const BOOT_FRAME: WorldFrame = { ...Place.termFrame };
const PERSIST_DEBOUNCE_MS = 200;
const ZOOM_STEP = 1.2; // ZoomControl.zoomStep — ± multiply/divide by this
const TOAST_PRUNE_MS = 250;

// Offscreen-hint layout constants (OffscreenHints.swift).
const HINT_EDGE_INSET = 18;
const HINT_EDGE_MARGIN = 10;
const HINT_STACK_GAP = 8;

/** Per-doc metadata kept off the card (so a shelved doc keeps its color/owner). */
interface DocMeta {
  repoColor?: number;
  ownerTermId?: string;
}

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

export default function App() {
  const [cards, setCards] = useState<CardModel[]>([]);
  const [docContents, setDocContents] = useState<Map<string, string>>(new Map());
  const [shelfPaths, setShelfPaths] = useState<string[]>([]);
  const [status, setStatus] = useState<DaemonStatus>({ connected: false, reason: "connecting…" });

  // Phase 4 chrome state.
  const [viewport, setViewportState] = useState<Viewport>({ zoom: 1, cx: 0, cy: 0 });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [toastState, setToastState] = useState<ToastState>(emptyToasts);
  const [peekVisible, setPeekVisible] = useState(false);
  const [peekPath, setPeekPath] = useState<string | null>(null);

  const engineRef = useRef<BoardEngine | null>(null);
  const cardsRef = useRef<CardModel[]>([]);
  cardsRef.current = cards;
  const shelfRef = useRef<string[]>([]);
  shelfRef.current = shelfPaths;

  const didRestoreRef = useRef(false);
  const boardIdRef = useRef<string | null>(null);
  const dockOrderRef = useRef<string[]>([]);
  const docMetaRef = useRef<Map<string, DocMeta>>(new Map());
  const gestureRef = useRef<Gesture | null>(null);
  const persistTimer = useRef<number | null>(null);

  // Recency + bell timestamps (view-layer clock; drive the peek target + bell pill).
  const lastChangedRef = useRef<Map<string, number>>(new Map());
  const bellTimeRef = useRef<Map<string, number>>(new Map());
  // Mirrors for the once-registered keydown handler's closure.
  const peekVisibleRef = useRef(false);
  peekVisibleRef.current = peekVisible;
  const peekPathRef = useRef<string | null>(null);
  peekPathRef.current = peekPath;
  const toastsRef = useRef<Toast[]>([]);
  toastsRef.current = toastState.toasts;
  const flyTargetRef = useRef<string | null>(null);
  const preFlightRef = useRef<Viewport | null>(null);
  const prevConnectedRef = useRef(false);
  // rAF-coalesce the viewport state update so a pan/zoom burst re-renders the
  // chrome at most once per frame (keeps the cards off the 60fps hot path).
  const vpRafRef = useRef<number | null>(null);
  const pendingVpRef = useRef<Viewport | null>(null);

  // --- card factories ------------------------------------------------------

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

  // --- persistence (layout + viewport) -------------------------------------

  const buildAndSend = () => {
    if (!didRestoreRef.current) return; // never overwrite the saved layout pre-restore
    const terms = [];
    const docs = [];
    for (const c of cardsRef.current) {
      if (c.kind === "term") terms.push({ termId: c.termId, frame: c.frame, z: c.z, dead: c.dead });
      else docs.push({ path: c.path, frame: c.frame, z: c.z, attached: c.attached });
    }
    const tiles = buildTiles(terms, docs, shelfRef.current);
    const vp = engineRef.current?.viewport ?? { zoom: 1, cx: 0, cy: 0 };
    void persistLayout(
      dockOrderRef.current,
      tiles,
      { zoom: vp.zoom, cx: vp.cx, cy: vp.cy },
      boardIdRef.current,
    );
  };

  /** Coalesce a burst (pan/zoom, multi-card change) onto a 200ms trailing send. */
  const schedulePersist = () => {
    if (persistTimer.current != null) clearTimeout(persistTimer.current);
    persistTimer.current = window.setTimeout(() => {
      persistTimer.current = null;
      buildAndSend();
    }, PERSIST_DEBOUNCE_MS);
  };

  /** Flush any pending snapshot now (board blur / window close) so it's not lost. */
  const flushPersist = () => {
    if (persistTimer.current == null) return;
    clearTimeout(persistTimer.current);
    persistTimer.current = null;
    buildAndSend();
  };

  // Persist on any committed card-set / frame / shelf change (debounced). The
  // viewport persists via onViewport below; both share the same trailing timer.
  useEffect(schedulePersist, [cards, shelfPaths]);

  /** Committed pan/zoom: persist (debounced) immediately, and coalesce the chrome
   * viewport state update onto one rAF so a wheel/pinch burst re-renders the chrome
   * at most once per frame rather than per event. */
  const onViewport = (vp: Viewport) => {
    schedulePersist();
    pendingVpRef.current = vp;
    if (vpRafRef.current != null) return;
    vpRafRef.current = requestAnimationFrame(() => {
      vpRafRef.current = null;
      if (pendingVpRef.current) setViewportState(pendingVpRef.current);
    });
  };

  // --- toasts --------------------------------------------------------------

  const pushToast = (t: Omit<Toast, "expiresAtMs" | "id">) =>
    setToastState((s) => addToast(s, { ...t, id: mint() }, Date.now()));

  const onToastChip = (toastId: string, _chipIndex: number) =>
    // No chip actions wired yet (the undo chip lands with ⌘W close in P5); dismiss.
    setToastState((s) => dismissToast(s, toastId));

  // Auto-expire toasts off a single interval while the stack is non-empty.
  useEffect(() => {
    if (toastState.toasts.length === 0) return;
    const id = window.setInterval(() => setToastState((s) => pruneExpired(s, Date.now())), TOAST_PRUNE_MS);
    return () => window.clearInterval(id);
  }, [toastState.toasts.length]);

  // --- doc content ---------------------------------------------------------

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
    if (!cardsRef.current.some((c) => c.kind === "doc" && c.path === path)) return;
    void fetchDoc(path);
  };

  // --- doc landing (gravity placement) + shelf -----------------------------

  const landDoc = (path: string, via: string, ownerTermId?: string, repoColor?: number) => {
    const prev = docMetaRef.current.get(path);
    docMetaRef.current.set(path, {
      repoColor: repoColor ?? prev?.repoColor,
      ownerTermId: ownerTermId ?? prev?.ownerTermId,
    });
    if (!dockOrderRef.current.includes(path)) dockOrderRef.current = [...dockOrderRef.current, path];
    void fetchDoc(path);
    setShelfPaths((sp) => (sp.includes(path) ? sp.filter((p) => p !== path) : sp));

    setCards((cs) => {
      const onBoard = cs.find((c) => c.kind === "doc" && c.path === path);
      if (onBoard) {
        // Re-open: refresh owner/color/fresh in place, never move (Swift parity).
        return cs.map((c) =>
          c.kind === "doc" && c.path === path
            ? {
                ...c,
                ownerTermId: ownerTermId ?? c.ownerTermId,
                repoColor: repoColor ?? c.repoColor,
                fresh: via === "cli" ? true : c.fresh,
              }
            : c,
        );
      }
      const owner = ownerTermId
        ? (cs.find((c) => c.kind === "term" && c.termId === ownerTermId) as TermCardModel | undefined)
        : undefined;
      const prime = cs.find((c) => c.kind === "term" && c.prime) as TermCardModel | undefined;
      const anchor = owner?.frame ?? prime?.frame ?? BOOT_FRAME;
      const frame = firstFreeSlot(anchor, cs.map((c) => c.frame));
      const doc: DocCardModel = {
        kind: "doc",
        path,
        frame,
        z: topZ(cs) + 1,
        ownerTermId,
        repoColor,
        fresh: via === "cli",
        attached: ownerTermId != null,
      };
      return [...cs, doc];
    });
  };

  const moveToShelf = (path: string) => {
    setCards((cs) => cs.filter((c) => !(c.kind === "doc" && c.path === path)));
    setShelfPaths((sp) => (sp.includes(path) ? sp : [...sp, path]));
  };

  /** Bring a shelved doc back to the board — at the drop point (drag) or the next
   * free slot near the prime terminal (click). Restored docs land loose. */
  const restoreFromShelf = (path: string, drop?: { clientX: number; clientY: number }) => {
    const meta = docMetaRef.current.get(path);
    let frame: WorldFrame;
    if (drop && engineRef.current) {
      const w = engineRef.current.viewToWorld(drop.clientX, drop.clientY);
      frame = { x: w.x - Place.docW / 2, y: w.y - 15, w: Place.docW, h: Place.docH };
    } else {
      const prime = cardsRef.current.find((c) => c.kind === "term" && c.prime) as
        | TermCardModel
        | undefined;
      frame = firstFreeSlot(prime?.frame ?? BOOT_FRAME, cardsRef.current.map((c) => c.frame));
    }
    setShelfPaths((sp) => sp.filter((p) => p !== path));
    setCards((cs) =>
      cs.some((c) => c.kind === "doc" && c.path === path)
        ? cs
        : [
            ...cs,
            {
              kind: "doc",
              path,
              frame,
              z: topZ(cs) + 1,
              ownerTermId: meta?.ownerTermId,
              repoColor: meta?.repoColor,
              fresh: false,
              attached: false,
            } as DocCardModel,
          ],
    );
    void fetchDoc(path);
  };

  // --- peek (⌘P quick-look of the most-recent doc) -------------------------

  /** The doc to peek: most-recently-changed, else the most-recently-opened. */
  const peekTarget = (): string | null => {
    let best: string | null = null;
    let bestT = -Infinity;
    for (const [p, t] of lastChangedRef.current) {
      if (t > bestT) {
        bestT = t;
        best = p;
      }
    }
    if (best) return best;
    const order = dockOrderRef.current;
    return order.length ? order[order.length - 1]! : null;
  };

  const openPeek = () => {
    const target = peekTarget();
    if (!target) return; // nothing to peek (empty registry)
    void fetchDoc(target);
    setPeekPath(target);
    setPeekVisible(true);
    // Presenting the doc marks it read — clear its fresh state.
    setCards((cs) => cs.map((c) => (c.kind === "doc" && c.path === target ? { ...c, fresh: false } : c)));
  };

  /** ⌘⏎ / pin chip: if the peeked doc is on the board, unpin it to the shelf; else
   * land it at a free slot. Either way the peek closes. */
  const togglePinPeeked = () => {
    const p = peekPathRef.current;
    if (!p) return;
    if (cardsRef.current.some((c) => c.kind === "doc" && c.path === p)) moveToShelf(p);
    else restoreFromShelf(p);
    setPeekVisible(false);
  };

  // --- terminal lifecycle --------------------------------------------------

  const spawnNewTerminal = () => {
    const existing = cardsRef.current;
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
    setCards((cs) => [...cs.map(unprime), term]);
  };

  const handleExit = (termId: string, code: number | null) => {
    const term = cardsRef.current.find((c) => c.kind === "term" && c.termId === termId) as
      | TermCardModel
      | undefined;
    if (!term) return;
    // Surface a non-clean exit as a toast (clean code 0 stays silent).
    if (code !== 0) {
      pushToast({
        icon: "›_",
        title: code == null ? "killed by signal" : `shell exited · ${code}`,
        body: null,
        chips: [],
      });
    }
    const others = cardsRef.current.filter(
      (c) => c.kind === "term" && c.termId !== termId && c.live && !c.dead,
    ).length;
    const action = decide(code, others);
    if (action === "holdOpen") {
      setCards((cs) =>
        reassignPrime(
          cs.map((c) =>
            c.kind === "term" && c.termId === termId
              ? { ...c, live: false, dead: true, prime: false }
              : c,
          ),
        ),
      );
    } else if (action === "remove") {
      setCards((cs) => reassignPrime(cs.filter((c) => !(c.kind === "term" && c.termId === termId))));
    } else {
      // removeAndReplace: keep ≥1 live terminal by spawning a fresh one in place.
      const { frame, z } = term;
      const fresh = makeTerm(mint(), frame, z, { needsSpawn: true, prime: true });
      setCards((cs) => [
        ...cs.filter((c) => !(c.kind === "term" && c.termId === termId)).map(unprime),
        fresh,
      ]);
    }
  };

  const onTermSpawn = (termId: string, cols: number, rows: number) => {
    const term = cardsRef.current.find((c) => c.kind === "term" && c.termId === termId) as
      | TermCardModel
      | undefined;
    if (!term) return;
    if (term.needsSpawn) {
      void spawnTerm({ termId, cols, rows, boardId: boardIdRef.current ?? undefined });
      setCards((cs) =>
        cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, needsSpawn: false } : c)),
      );
    } else {
      // Re-bound to a daemon-live pty: don't spawn (duplicate shell); sync its size.
      void termResize(termId, cols, rows);
    }
  };

  const applyTermProc = (termId: string, name: string) =>
    setCards((cs) =>
      cs.map((c) =>
        c.kind === "term" && c.termId === termId
          ? { ...c, label: displayLabel(undefined, name, "shell") }
          : c,
      ),
    );

  /** A keystroke into a terminal clears its bell (Swift parity). TerminalCard only
   * calls this when a bell is lit, and we bail to the same ref otherwise, so normal
   * typing never re-renders. */
  const onTermActivity = (termId: string) =>
    setCards((cs) => {
      if (!cs.some((c) => c.kind === "term" && c.termId === termId && c.bell)) return cs;
      bellTimeRef.current.delete(termId);
      return cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, bell: false } : c));
    });

  // --- restore (cold start: tiles + live_terms → cards) --------------------

  const applyRestore = (msg: Extract<DaemonMsg, { t: "restore" }>) => {
    if (didRestoreRef.current) return; // reconnect revive is Phase 5; apply once
    didRestoreRef.current = true;
    boardIdRef.current = msg.board_id ?? null;

    const docs = msg.docs ?? [];
    dockOrderRef.current = docs.map((d) => d.path);
    for (const d of docs) {
      docMetaRef.current.set(d.path, {
        repoColor: d.repo_color ?? undefined,
        ownerTermId: d.term_id ?? undefined,
      });
    }

    const { termTiles, docTiles, shelfPaths: restoredShelf } = parseTiles(
      (msg.tiles ?? []) as unknown as LayoutTile[],
    );
    const liveTerms = new Set(msg.live_terms ?? []);

    // Terminals: TermRestore.plan partitions each tile into rebind vs cold-spawn.
    const plans = plan(
      termTiles.map((t) => t.termId),
      liveTerms,
    );
    const oldToNew = new Map<string, string>(); // persisted id → reborn id (cold-spawn mints fresh)
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
        return makeTerm(p.termId, frame, t.z, { needsSpawn: false });
      }
      const id = mint();
      if (t.termId) oldToNew.set(t.termId, id);
      return makeTerm(id, frame, t.z, { needsSpawn: true });
    });
    // Guarantee ≥1 terminal (M1 / empty layout → one cold-spawn boot terminal).
    if (newTerms.length === 0) {
      newTerms.push(makeTerm(mint(), BOOT_FRAME, 0, { needsSpawn: true }));
    }
    newTerms[0]!.prime = true;

    // Docs: place geometry-bearing tiles; M1 (geometry-less) scatter; shelf → chips.
    let scatterSlot = 0;
    const newDocs: DocCardModel[] = [];
    for (const dt of docTiles) {
      if (!docMetaRef.current.has(dt.path)) {
        // Receiver rule: a tile for a doc the registry doesn't know is dropped.
        console.warn(`restore: doc tile ${dt.path} absent from the registry — dropping`);
        continue;
      }
      const meta = docMetaRef.current.get(dt.path)!;
      // Re-anchor the owner to its reborn id. If the owner terminal did NOT come
      // back (it had exited, so it has no tile/plan and no oldToNew entry), the
      // doc detaches rather than dangle to a ghost term that no edge/gravity matches.
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

    setCards([...newTerms, ...newDocs]);
    setShelfPaths(restoredShelf.filter((p) => docMetaRef.current.has(p)));

    const vp = msg.board
      ? { zoom: msg.board.zoom, cx: msg.board.cx, cy: msg.board.cy }
      : { zoom: 1, cx: 0, cy: 0 };
    engineRef.current?.setViewport(vp);
  };

  // --- daemon stream -------------------------------------------------------

  const handle = (msg: DaemonMsg) => {
    switch (msg.t) {
      case "restore":
        applyRestore(msg);
        break;
      case "doc_opened":
        lastChangedRef.current.set(msg.path, Date.now());
        landDoc(msg.path, msg.via, msg.term_id ?? undefined, msg.repo_color ?? undefined);
        break;
      case "file_event":
        lastChangedRef.current.set(msg.path, Date.now());
        refreshDoc(msg.path);
        break;
      case "exit":
        handleExit(msg.term_id, msg.code ?? null);
        break;
      case "term_proc":
        applyTermProc(msg.term_id, msg.name);
        break;
      case "bell":
        bellTimeRef.current.set(msg.term_id, Date.now());
        setCards((cs) =>
          cs.map((c) => (c.kind === "term" && c.termId === msg.term_id ? { ...c, bell: true } : c)),
        );
        break;
      default:
        break; // hello_ok / board_list / err / unknown — ignored in this slice
    }
  };

  /** Connection status, raising a toast on a connected→lost transition. */
  const handleStatus = (s: DaemonStatus) => {
    setStatus(s);
    if (prevConnectedRef.current && !s.connected) {
      pushToast({ icon: "¶", title: "tarmacd connection lost", body: s.reason ?? null, chips: [] });
    }
    prevConnectedRef.current = s.connected;
  };

  useEffect(() => {
    const subs = [onDaemonStatus(handleStatus), onDaemonMsg(handle)];
    void Promise.all(subs).then(frontendReady);

    const onKeyDown = (e: KeyboardEvent) => {
      // ⌘T — new terminal (cascade-spawn).
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
      // ⌘⏎ — pin / unpin the peeked doc (only while peeking).
      if (e.metaKey && e.key === "Enter") {
        if (peekVisibleRef.current) {
          e.preventDefault();
          togglePinPeeked();
        }
        return;
      }
      // ⏎ — fly to the highest-priority offscreen signal, unless a terminal is
      // typing (it owns Return) or there is no target.
      if (e.key === "Enter" && !e.metaKey && !e.altKey && !e.ctrlKey) {
        const active = document.activeElement as HTMLElement | null;
        // The terminal owns Return; never hijack it from a focused control/field
        // either (defense-in-depth — chrome buttons also keep focus off themselves).
        if (active?.closest?.(".term-host, button, input, textarea, [contenteditable]")) return;
        const target = flyTargetRef.current;
        if (target && engineRef.current) {
          const card = cardsRef.current.find((c) => cardId(c) === target);
          if (card) {
            preFlightRef.current = engineRef.current.viewport;
            engineRef.current.flyToCard(card.frame);
            e.preventDefault();
          }
        }
        return;
      }
      // ESC ladder: peek → toasts → fly-back → fresh-doc-to-shelf (Swift order).
      if (e.key === "Escape") {
        if (peekVisibleRef.current) {
          e.preventDefault();
          setPeekVisible(false);
          return;
        }
        if (toastsRef.current.length > 0) {
          e.preventDefault();
          setToastState((s) => clearAllToasts(s));
          return;
        }
        if (preFlightRef.current && engineRef.current) {
          e.preventDefault();
          engineRef.current.flyTo(preFlightRef.current);
          preFlightRef.current = null;
          return;
        }
        // A fresh (just-landed) doc card dismisses to the shelf; otherwise ESC
        // passes through to the prime terminal's program (agent-interrupt / vim).
        const fresh = cardsRef.current.find((c) => c.kind === "doc" && c.fresh) as
          | DocCardModel
          | undefined;
        if (fresh) {
          e.preventDefault();
          moveToShelf(fresh.path);
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    window.addEventListener("blur", flushPersist);
    window.addEventListener("beforeunload", flushPersist);

    return () => {
      subs.forEach((p) => void p.then((off) => off()));
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("blur", flushPersist);
      window.removeEventListener("beforeunload", flushPersist);
      if (vpRafRef.current != null) cancelAnimationFrame(vpRafRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- card gestures (move + gravity + grab/select-to-front) ---------------

  const onCardMoveStart = (id: string) => {
    const card = cardsRef.current.find((c) => cardId(c) === id);
    if (!card) return;
    if (card.kind === "term") {
      const sats = new Map<string, WorldFrame>();
      for (const c of cardsRef.current) {
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
      setCards((cs) =>
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
      setCards((cs) => cs.map((c) => (cardId(c) === id ? ({ ...c, frame } as CardModel) : c)));
    }
  };

  const onCardMoveEnd = (id: string) => {
    const g = gestureRef.current;
    gestureRef.current = null;
    if (g && g.kind === "doc" && `doc:${g.path}` === id) {
      // A manual move severs gravity: the doc no longer follows its owner.
      setCards((cs) =>
        cs.map((c) =>
          c.kind === "doc" && c.path === g.path ? { ...c, attached: false, fresh: false } : c,
        ),
      );
    }
    // The [cards] effect persists the committed positions (debounced).
  };

  /** Resize commits a frame-only change (no gravity / satellites). */
  const onCardResize = (id: string, frame: WorldFrame) =>
    setCards((cs) => cs.map((c) => (cardId(c) === id ? ({ ...c, frame } as CardModel) : c)));

  const onCardResizeEnd = (_id: string) => {
    // The [cards] effect persists the committed size (debounced).
  };

  const onCardGrab = (id: string) => {
    setSelectedId(id); // the grabbed card becomes the active (ring + handles) card
    setCards((cs) => {
      const target = cs.find((c) => cardId(c) === id);
      if (!target) return cs;
      const top = topZ(cs) + 1;
      // Only a LIVE terminal takes prime; grabbing a dead placeholder or a doc
      // just raises it to front (a dead card must never become the typing target).
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
    engine.setViewport({ zoom: vp.zoom, cx: world.x, cy: world.y }); // re-center, keep zoom
  };

  // --- offscreen hints + minimap (recompute on card/viewport change) -------

  const hhmmFor = (c: CardModel): string =>
    c.kind === "term" ? formatClock(bellTimeRef.current.get(c.termId) ?? Date.now()) : formatClock(Date.now());

  const offscreen = useMemo<{ pills: PlacedPill[]; flyTarget: string | null }>(() => {
    const engine = engineRef.current;
    if (!engine) return { pills: [], flyTarget: null };
    const wr = engine.viewportWorldRect;
    const size = engine.viewportSize;
    const hints: OffscreenHint[] = [];
    for (const c of cards) {
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
  }, [cards, viewport]);
  flyTargetRef.current = offscreen.flyTarget;

  const engine = engineRef.current;
  const minimapItems: MinimapItem[] = cards.map((c) => ({
    worldRect: c.frame,
    signal: (cardSignal(c) ?? "none") as MinimapSignal,
  }));
  const viewportWorldRect = engine ? engine.viewportWorldRect : { x: 0, y: 0, w: 0, h: 0 };

  return (
    <div className="app">
      <div className="board-stack">
        <Board
          cards={cards}
          docContents={docContents}
          engineRef={engineRef}
          onViewport={onViewport}
          onCardMove={onCardMove}
          onCardMoveStart={onCardMoveStart}
          onCardMoveEnd={onCardMoveEnd}
          onCardResize={onCardResize}
          onCardResizeEnd={onCardResizeEnd}
          onCardGrab={onCardGrab}
          onTermSpawn={onTermSpawn}
          onTermTitle={(termId, title) =>
            title.trim()
              ? setCards((cs) =>
                  cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, label: title } : c)),
                )
              : undefined
          }
          onTermActivity={onTermActivity}
          onDocClose={moveToShelf}
          selectedId={selectedId}
          onBackgroundPointerDown={() => setSelectedId(null)}
        />
        <TitleBarChip name={boardChipLabel(null, "tarmac")} attached={status.connected} />
        <ShelfOverlay
          paths={shelfPaths}
          repoColorFor={(p) => docMetaRef.current.get(p)?.repoColor}
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
          markdown={peekPath ? docContents.get(peekPath) ?? "" : ""}
          repoColor={peekPath ? docMetaRef.current.get(peekPath)?.repoColor : undefined}
          lastChangedMs={peekPath ? lastChangedRef.current.get(peekPath) : undefined}
          onPin={togglePinPeeked}
          onClose={() => setPeekVisible(false)}
        />
        <ToastOverlay toasts={toastState.toasts} onChipClick={onToastChip} />
      </div>
      <StatusBar connected={status.connected} reason={status.reason} cards={cards.length} />
    </div>
  );
}
