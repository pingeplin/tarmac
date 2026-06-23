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
  onDocClose: (path: string) => void;
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

  return (
    <div className="board" ref={viewportRef}>
      <div className="world" ref={worldRef}>
        <EdgeLayer cards={cards} />
        {cards.map((c) => {
          const id = cardId(c);
          return c.kind === "term" ? (
            <TerminalCard
              key={id}
              model={c}
              getZoom={getZoom}
              rootRef={setEl(id)}
              onMove={(frame) => props.onCardMove(id, frame)}
              onMoveStart={() => props.onCardMoveStart(id)}
              onMoveEnd={() => props.onCardMoveEnd(id)}
              onGrab={() => props.onCardGrab(id)}
              onSpawn={(cols, rows) => props.onTermSpawn(c.termId, cols, rows)}
              onTitle={(title) => props.onTermTitle(c.termId, title)}
            />
          ) : (
            <DocCard
              key={id}
              model={c}
              markdown={props.docContents.get(c.path) ?? ""}
              getZoom={getZoom}
              rootRef={setEl(id)}
              onMove={(frame) => props.onCardMove(id, frame)}
              onMoveStart={() => props.onCardMoveStart(id)}
              onMoveEnd={() => props.onCardMoveEnd(id)}
              onGrab={() => props.onCardGrab(id)}
              onClose={() => props.onDocClose(c.path)}
            />
          );
        })}
      </div>
    </div>
  );
}
