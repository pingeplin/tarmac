// The infinite-canvas host: a clipping viewport + a transform-origin world layer
// driven by BoardEngine. Cards (DOM nodes at world coords) live inside the world;
// the engine writes the world transform on pan/zoom. React only re-renders when
// the card SET or a card's committed frame changes. Each card's root node is
// registered with the engine so it can cull off-screen cards (visibility:hidden,
// node kept alive) on the pan/zoom hot path without a React re-render.

import { useEffect, useRef, type MutableRefObject } from "react";
import { BoardEngine, type Cullable, type Viewport } from "./BoardEngine";
import { EdgeLayer } from "./EdgeLayer";
import { TerminalCard } from "../cards/TerminalCard";
import { DocCard } from "../cards/DocCard";
import { cardId, type CardModel, type WorldFrame } from "./model";

interface BoardProps {
  cards: CardModel[];
  docContents: Map<string, string>;
  engineRef: MutableRefObject<BoardEngine | null>;
  onViewport?: (vp: Viewport) => void;
  onCardMove: (id: string, frame: WorldFrame) => void;
  onCardMoveStart: (id: string) => void;
  onCardMoveEnd: (id: string) => void;
  onCardGrab: (id: string) => void;
  onTermSpawn: (termId: string, cols: number, rows: number) => void;
  onTermTitle: (termId: string, title: string) => void;
  onTermActivity: (termId: string) => void;
  onDocClose: (path: string) => void;
  /** The active card (shows the focus ring + resize handles), or null. */
  selectedId: string | null;
  /** A press on empty board space clears the selection. */
  onBackgroundPointerDown: () => void;
  onCardResize: (id: string, frame: WorldFrame) => void;
  onCardResizeEnd: (id: string) => void;
}

export function Board(props: BoardProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const worldRef = useRef<HTMLDivElement>(null);
  const cardEls = useRef<Map<string, HTMLElement>>(new Map());
  const { engineRef, cards } = props;

  useEffect(() => {
    if (!viewportRef.current || !worldRef.current) return;
    const engine = new BoardEngine(viewportRef.current, worldRef.current);
    engine.onViewportChange = props.onViewport;
    engineRef.current = engine;
    // Seed the chrome (zoom readout, minimap, offscreen hints) with the initial
    // viewport so the overlays populate before the first pan/zoom.
    props.onViewport?.(engine.viewport);
    return () => {
      engine.destroy();
      engineRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // After every committed card-set / frame change, hand the engine the current
  // card nodes + world frames so its hot-path culling has fresh geometry.
  useEffect(() => {
    const engine = engineRef.current;
    if (!engine) return;
    const cullables: Cullable[] = [];
    for (const c of cards) {
      const el = cardEls.current.get(cardId(c));
      if (el) cullables.push({ id: cardId(c), el, frame: c.frame });
    }
    engine.setCullables(cullables);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cards]);

  const getZoom = () => engineRef.current?.viewport.zoom ?? 1;
  const setEl = (id: string) => (el: HTMLDivElement | null) => {
    if (el) cardEls.current.set(id, el);
    else cardEls.current.delete(id);
  };

  // A non-prime terminal dims (quiet) while another terminal holds prime.
  const anyTermPrime = cards.some((c) => c.kind === "term" && c.prime);

  return (
    <div
      className="board"
      ref={viewportRef}
      onPointerDown={(e) => {
        // A press on empty board space (not a card) clears the selection.
        if (e.target === viewportRef.current || e.target === worldRef.current) {
          props.onBackgroundPointerDown();
        }
      }}
    >
      <div className="world" ref={worldRef}>
        <EdgeLayer cards={cards} />
        {cards.map((c) => {
          const id = cardId(c);
          const selected = id === props.selectedId;
          return c.kind === "term" ? (
            <TerminalCard
              key={id}
              model={c}
              selected={selected}
              quiet={anyTermPrime && !c.prime && !c.dead}
              getZoom={getZoom}
              rootRef={setEl(id)}
              onMove={(frame) => props.onCardMove(id, frame)}
              onMoveStart={() => props.onCardMoveStart(id)}
              onMoveEnd={() => props.onCardMoveEnd(id)}
              onResize={(frame) => props.onCardResize(id, frame)}
              onResizeEnd={() => props.onCardResizeEnd(id)}
              onGrab={() => props.onCardGrab(id)}
              onSpawn={(cols, rows) => props.onTermSpawn(c.termId, cols, rows)}
              onTitle={(title) => props.onTermTitle(c.termId, title)}
              onActivity={() => props.onTermActivity(c.termId)}
            />
          ) : (
            <DocCard
              key={id}
              model={c}
              markdown={props.docContents.get(c.path) ?? ""}
              selected={selected}
              detached={c.ownerTermId != null && !c.attached}
              getZoom={getZoom}
              rootRef={setEl(id)}
              onMove={(frame) => props.onCardMove(id, frame)}
              onMoveStart={() => props.onCardMoveStart(id)}
              onMoveEnd={() => props.onCardMoveEnd(id)}
              onResize={(frame) => props.onCardResize(id, frame)}
              onResizeEnd={() => props.onCardResizeEnd(id)}
              onGrab={() => props.onCardGrab(id)}
              onClose={() => props.onDocClose(c.path)}
            />
          );
        })}
      </div>
    </div>
  );
}
