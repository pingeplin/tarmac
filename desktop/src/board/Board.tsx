// The infinite-canvas host: a clipping viewport + a transform-origin world layer
// driven by BoardEngine. Cards (DOM nodes at world coords) live inside the world;
// the engine writes the world transform on pan/zoom. React only re-renders when
// the card SET or a card's committed frame changes.

import { useEffect, useRef, type MutableRefObject } from "react";
import { BoardEngine, type Viewport } from "./BoardEngine";
import { EdgeLayer } from "./EdgeLayer";
import { TerminalCard } from "../cards/TerminalCard";
import { DocCard } from "../cards/DocCard";
import type { CardModel, WorldFrame } from "./model";

interface BoardProps {
  cards: CardModel[];
  docContents: Map<string, string>;
  engineRef: MutableRefObject<BoardEngine | null>;
  onViewport?: (vp: Viewport) => void;
  onCardMove: (id: string, frame: WorldFrame) => void;
  onCardGrab: (id: string) => void;
  onTermSpawn: (termId: string, cols: number, rows: number) => void;
  onTermTitle: (termId: string, title: string) => void;
  onDocClose: (path: string) => void;
}

export function Board(props: BoardProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const worldRef = useRef<HTMLDivElement>(null);
  const { engineRef } = props;

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

  const getZoom = () => engineRef.current?.viewport.zoom ?? 1;

  return (
    <div className="board" ref={viewportRef}>
      <div className="world" ref={worldRef}>
        <EdgeLayer cards={props.cards} />
        {props.cards.map((c) =>
          c.kind === "term" ? (
            <TerminalCard
              key={`term:${c.termId}`}
              model={c}
              getZoom={getZoom}
              onMove={(frame) => props.onCardMove(`term:${c.termId}`, frame)}
              onGrab={() => props.onCardGrab(`term:${c.termId}`)}
              onSpawn={(cols, rows) => props.onTermSpawn(c.termId, cols, rows)}
              onTitle={(title) => props.onTermTitle(c.termId, title)}
            />
          ) : (
            <DocCard
              key={`doc:${c.path}`}
              model={c}
              markdown={props.docContents.get(c.path) ?? ""}
              getZoom={getZoom}
              onMove={(frame) => props.onCardMove(`doc:${c.path}`, frame)}
              onGrab={() => props.onCardGrab(`doc:${c.path}`)}
              onClose={() => props.onDocClose(c.path)}
            />
          ),
        )}
      </div>
    </div>
  );
}
