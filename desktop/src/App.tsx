// The cockpit orchestrator: subscribes to the daemon stream, owns the board's
// card set, runs the multi-terminal lifecycle (boot/⌘T/exit/prime), lands
// `tarmac open` docs with gravity placement + a provenance edge, parks docs on a
// shelf, and round-trips the whole layout (tiles + viewport) to the daemon so a
// board survives a restart. This is AppController.swift's whiteboard core minus
// the multi-board switcher + overlay chrome (Phases 4–5).

import { useEffect, useRef, useState } from "react";
import { Board } from "./board/Board";
import { StatusBar } from "./ui/StatusBar";
import { ShelfOverlay } from "./ui/ShelfOverlay";
import type { BoardEngine } from "./board/BoardEngine";
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
import { cascadeOrigin } from "./kit/boardWayfinding";
import { Place, firstFreeSlot, scatterFrame } from "./kit/placement";
import { buildTiles, parseTiles, type LayoutTile } from "./kit/layoutTiles";
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

export default function App() {
  const [cards, setCards] = useState<CardModel[]>([]);
  const [docContents, setDocContents] = useState<Map<string, string>>(new Map());
  const [shelfPaths, setShelfPaths] = useState<string[]>([]);
  const [status, setStatus] = useState<DaemonStatus>({ connected: false, reason: "connecting…" });

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
        landDoc(msg.path, msg.via, msg.term_id ?? undefined, msg.repo_color ?? undefined);
        break;
      case "file_event":
        refreshDoc(msg.path);
        break;
      case "exit":
        handleExit(msg.term_id, msg.code ?? null);
        break;
      case "term_proc":
        applyTermProc(msg.term_id, msg.name);
        break;
      case "bell":
        setCards((cs) =>
          cs.map((c) => (c.kind === "term" && c.termId === msg.term_id ? { ...c, bell: true } : c)),
        );
        break;
      default:
        break; // hello_ok / board_list / err / unknown — ignored in this slice
    }
  };

  useEffect(() => {
    const subs = [onDaemonStatus(setStatus), onDaemonMsg(handle)];
    void Promise.all(subs).then(frontendReady);

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.metaKey && !e.altKey && !e.ctrlKey && e.key.toLowerCase() === "t") {
        e.preventDefault();
        spawnNewTerminal();
        return;
      }
      if (e.key === "Escape") {
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

  const onCardGrab = (id: string) => {
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

  return (
    <div className="app">
      <Board
        cards={cards}
        docContents={docContents}
        engineRef={engineRef}
        onViewport={schedulePersist}
        onCardMove={onCardMove}
        onCardMoveStart={onCardMoveStart}
        onCardMoveEnd={onCardMoveEnd}
        onCardGrab={onCardGrab}
        onTermSpawn={onTermSpawn}
        onTermTitle={(termId, title) =>
          title.trim()
            ? setCards((cs) =>
                cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, label: title } : c)),
              )
            : undefined
        }
        onDocClose={moveToShelf}
      />
      <ShelfOverlay
        paths={shelfPaths}
        repoColorFor={(p) => docMetaRef.current.get(p)?.repoColor}
        onRestore={restoreFromShelf}
      />
      <StatusBar connected={status.connected} reason={status.reason} cards={cards.length} />
    </div>
  );
}
