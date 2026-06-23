// The cockpit orchestrator: subscribes to the daemon stream, owns the board's
// card set, boots the first terminal, and lands `tarmac open` docs as cards with
// a provenance edge. This is the vertical-slice subset of AppController.swift —
// one board, terminals, doc cards. Overlays/boards/switcher come in later phases.

import { useEffect, useRef, useState } from "react";
import { Board } from "./board/Board";
import { StatusBar } from "./ui/StatusBar";
import type { BoardEngine } from "./board/BoardEngine";
import type { CardModel, TermCardModel, WorldFrame } from "./board/model";
import { mint } from "./kit/bootTerminal";
import { displayLabel } from "./kit/termTitle";
import { frontendReady, onDaemonMsg, onDaemonStatus, readDoc, spawnTerm } from "./ipc/daemon";
import type { DaemonMsg, DaemonStatus } from "./ipc/protocol";

const BOOT_FRAME: WorldFrame = { x: -380, y: -250, w: 760, h: 480 };

export default function App() {
  const [cards, setCards] = useState<CardModel[]>([]);
  const [docContents, setDocContents] = useState<Map<string, string>>(new Map());
  const [status, setStatus] = useState<DaemonStatus>({ connected: false, reason: "connecting…" });

  const engineRef = useRef<BoardEngine | null>(null);
  const cardsRef = useRef<CardModel[]>([]);
  cardsRef.current = cards;
  const bootedRef = useRef(false);

  // --- card mutation helpers (committed events only) -----------------------

  const updateTerm = (termId: string, patch: Partial<TermCardModel>) =>
    setCards((cs) =>
      cs.map((c) => (c.kind === "term" && c.termId === termId ? { ...c, ...patch } : c)),
    );

  const moveCard = (id: string, frame: WorldFrame) =>
    setCards((cs) =>
      cs.map((c) => {
        const cid = c.kind === "term" ? `term:${c.termId}` : `doc:${c.path}`;
        return cid === id ? ({ ...c, frame } as CardModel) : c;
      }),
    );

  const bootTerminal = () => {
    if (bootedRef.current) return;
    bootedRef.current = true;
    const term: TermCardModel = {
      kind: "term",
      termId: mint(),
      frame: BOOT_FRAME,
      label: "shell",
      live: true,
      dead: false,
      prime: true,
      bell: false,
    };
    setCards((cs) => [...cs, term]);
  };

  const landDoc = async (path: string, via: string, ownerTermId?: string, repoColor?: number) => {
    // Place the doc to the right of its owning terminal (provenance), else cascade.
    const owner = cardsRef.current.find(
      (c) => c.kind === "term" && c.termId === ownerTermId,
    ) as TermCardModel | undefined;
    const frame: WorldFrame = owner
      ? { x: owner.frame.x + owner.frame.w + 60, y: owner.frame.y, w: 520, h: 460 }
      : { x: 60, y: -200, w: 520, h: 460 };

    let md = "";
    try {
      md = await readDoc(path);
    } catch (e) {
      md = `*could not read ${path}*\n\n\`\`\`\n${String(e)}\n\`\`\``;
    }
    setDocContents((m) => new Map(m).set(path, md));
    setCards((cs) => {
      if (cs.some((c) => c.kind === "doc" && c.path === path)) return cs; // already on board
      return [...cs, { kind: "doc", path, frame, ownerTermId, repoColor, fresh: via === "cli" }];
    });
  };

  const refreshDoc = async (path: string) => {
    if (!cardsRef.current.some((c) => c.kind === "doc" && c.path === path)) return;
    try {
      const md = await readDoc(path);
      setDocContents((m) => new Map(m).set(path, md));
    } catch {
      /* leave the last good render */
    }
  };

  // --- daemon stream -------------------------------------------------------

  const handle = (msg: DaemonMsg) => {
    switch (msg.t) {
      case "restore":
        // Cold-start slice: ensure exactly one boot terminal. (Persisted tile
        // restore + live_terms re-bind arrives in Phase 3.)
        if (!cardsRef.current.some((c) => c.kind === "term")) bootTerminal();
        break;
      case "doc_opened":
        void landDoc(msg.path, msg.via, msg.term_id ?? undefined, msg.repo_color ?? undefined);
        break;
      case "file_event":
        void refreshDoc(msg.path);
        break;
      case "exit":
        updateTerm(msg.term_id, { live: false, dead: true, prime: false });
        break;
      case "term_proc":
        updateTerm(msg.term_id, { label: displayLabel(undefined, msg.name, "shell") });
        break;
      case "bell":
        updateTerm(msg.term_id, { bell: true });
        break;
      default:
        break; // hello_ok / board_list / err / unknown — ignored in the slice
    }
  };

  useEffect(() => {
    const subs = [onDaemonStatus(setStatus), onDaemonMsg(handle)];
    // Only ask the bridge to replay once the listeners are actually registered,
    // else the replayed restore could race the same way the original did.
    void Promise.all(subs).then(frontendReady);
    return () => {
      subs.forEach((p) => void p.then((off) => off()));
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const grabCard = (id: string) => {
    const term = cards.find((c) => c.kind === "term" && `term:${c.termId}` === id) as
      | TermCardModel
      | undefined;
    if (!term) return; // grabbing a doc does not change the prime terminal
    setCards((cs) =>
      cs.map((c) =>
        c.kind === "term"
          ? { ...c, prime: c.termId === term.termId, bell: c.termId === term.termId ? false : c.bell }
          : c,
      ),
    );
  };

  return (
    <div className="app">
      <Board
        cards={cards}
        docContents={docContents}
        engineRef={engineRef}
        onCardMove={moveCard}
        onCardGrab={grabCard}
        onTermSpawn={(termId, cols, rows) => void spawnTerm({ termId, cols, rows })}
        onTermTitle={(termId, title) => (title.trim() ? updateTerm(termId, { label: title }) : undefined)}
        onDocClose={(path) =>
          setCards((cs) => cs.filter((c) => !(c.kind === "doc" && c.path === path)))
        }
      />
      <StatusBar connected={status.connected} reason={status.reason} cards={cards.length} />
    </div>
  );
}
