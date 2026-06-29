// The infinite-canvas host: a clipping viewport driven by BoardEngine. Cards
// live in a screen-space .card-layer; each card gets a translate-only outer
// wrapper (sized card{w,h}×zoom via calc()) carrying zIndex:c.z. Terminals add
// a second inner div (zoom-free var(--card-w/h)) with scale(var(--zoom)) so
// the host box is never zoom-reactive → no fit()/PTY-resize on zoom.
//
// P5 multi-board: App renders ONE Board per board simultaneously; inactive boards
// are display:none (hidden=true) so their xterm terminals stay WARM — output
// Channels stay attached and scrollback survives switch-back. FitAddon.fit() is a
// safe no-op at 0 size; the ResizeObserver fires on show → auto-refit on reveal.

import React, { useEffect, useRef, useState, type MutableRefObject } from "react";
import { BoardEngine, type Cullable, type Viewport } from "./BoardEngine";
import { EdgeLayer } from "./EdgeLayer";
import type { EdgeLayerHandle } from "./BoardEngine";
import { TerminalCard } from "../cards/TerminalCard";
import { DocCard } from "../cards/DocCard";
import { ownerChipName } from "../kit/ownerChip";
import { docDimmed } from "../kit/provenance";
import { docWrapperBox, docCardVars } from "../kit/docZoom";
import { termWrapperBox, termCardVars, termInnerBox } from "../kit/termZoom";
import { cardId, type CardModel, type WorldFrame, type DocMeta } from "./model";

interface BoardProps {
  /** Stable board id — used by App to key engines in enginesRef. */
  boardId: string;
  /** When true the board's root is display:none; terminals stay mounted + warm. */
  hidden: boolean;
  /** Called with the engine after mount, and with null on destroy. App populates
   * enginesRef so the active board's chrome (zoom/minimap/fly) can read it. */
  onEngineReady: (boardId: string, engine: BoardEngine | null) => void;
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
  docMeta: Map<string, DocMeta>;
  /** The active card (shows the focus ring + resize handles), or null. */
  selectedId: string | null;
  /** A press on empty board space clears the selection. */
  onBackgroundPointerDown: () => void;
  onCardResize: (id: string, frame: WorldFrame) => void;
  onCardResizeEnd: (id: string) => void;
}

export function Board(props: BoardProps) {
  const viewportRef = useRef<HTMLDivElement>(null);
  const cardLayerRef = useRef<HTMLDivElement>(null);
  const edgeLayerRef = useRef<EdgeLayerHandle | null>(null);
  const cardEls = useRef<Map<string, HTMLElement>>(new Map());
  const { engineRef, cards, boardId } = props;

  // rasterScale: 1 at rest, increases with zoom after settle. Cards subscribe to
  // the settled value so they only re-raster after the gesture is idle (~150ms).
  // They never re-derive zoom — this is the single source of truth per the spec.
  const [rasterScale, setRasterScale] = useState(1);

  useEffect(() => {
    if (!viewportRef.current) return;
    const engine = new BoardEngine(viewportRef.current);
    engine.edgesRef = edgeLayerRef;
    engine.onViewportChange = props.onViewport;
    engine.onRasterScaleSettle = setRasterScale;
    engineRef.current = engine;
    props.onEngineReady(boardId, engine);
    // Seed the chrome (zoom readout, minimap, offscreen hints) with the initial
    // viewport so the overlays populate before the first pan/zoom.
    props.onViewport?.(engine.viewport);
    return () => {
      engine.destroy();
      engineRef.current = null;
      props.onEngineReady(boardId, null);
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
    engine.setCards(cards);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cards]);

  const getZoom = () => engineRef.current?.viewport.zoom ?? 1;
  const setEl = (id: string) => (el: HTMLDivElement | null) => {
    if (el) cardEls.current.set(id, el);
    else cardEls.current.delete(id);
  };

  // A non-prime terminal dims (quiet) while another terminal holds prime.
  const anyTermPrime = cards.some((c) => c.kind === "term" && c.prime);

  // Owner-chip needs the owner terminal's CURRENT label; it lives on the sibling term
  // card. Gate on a LIVE owner (Swift resolveOwner filters to live term ids) so a doc
  // whose owner terminal has EXITED — a held-open dead card lingers with its label —
  // drops the chip instead of showing a stale owner.
  const termLabel = (termId: string): string | undefined =>
    (cards.find((c) => c.kind === "term" && c.termId === termId && c.live && !c.dead) as
      | { label: string }
      | undefined)?.label;

  return (
    <div
      className="board"
      ref={viewportRef}
      // display:none hides the board without unmounting — terminals stay warm
      // (P5 warm-board model). ResizeObserver fires on show → auto-refit.
      style={props.hidden ? { display: "none" } : undefined}
      onPointerDown={(e) => {
        // A press on empty board space (not a card) clears the selection AND moves
        // keyboard focus OFF the prime terminal — the React analog of Swift's
        // makeFirstResponder(board) on a background click. This makes the "board has
        // focus" state reachable, so a bare Return docks the prime terminal (the App
        // keydown guard bails while a .term-host owns focus). Focus returns when the
        // user clicks into a terminal, or via dock/cycle/board-switch.
        if (e.target === viewportRef.current || e.target === cardLayerRef.current) {
          props.onBackgroundPointerDown();
          const ae = document.activeElement as HTMLElement | null;
          if (ae?.closest?.(".term-host")) ae.blur();
        }
      }}
    >
      {/* Provenance edges: painted behind cards, pointer-events:none */}
      <EdgeLayer ref={edgeLayerRef} cards={cards} />
      {/* Screen-space card layer: no transform on the layer; each card wrapper
          is translated to screen position via calc() off --zoom/--world-tx/ty.
          zIndex:c.z on each outer wrapper → single stacking context, cross-type
          focus-on-top works. */}
      <div className="card-layer" ref={cardLayerRef}>
        {cards.filter((c) => c.kind === "term").map((c) => {
          const id = cardId(c);
          return (
            // Outer wrapper: termWrapperBox() translate-only (no scale) + real-px
            // size calc(--card-w*--zoom). Cullable element (setEl); zIndex here only.
            <div
              key={id}
              ref={setEl(id)}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                ...termWrapperBox(),
                ...(termCardVars(c.frame) as React.CSSProperties),
                zIndex: c.z,
              }}
            >
              {/* Inner wrapper: zoom-free var(--card-w/h) + scale(var(--zoom)).
                  Host box never changes size on zoom → no fit()/PTY-resize. */}
              <div style={termInnerBox() as React.CSSProperties}>
                <TerminalCard
                  model={c}
                  selected={id === props.selectedId}
                  quiet={anyTermPrime && !c.prime && !c.dead}
                  getZoom={getZoom}
                  rasterScale={rasterScale}
                  inWrapper
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
              </div>
            </div>
          );
        })}
        {/* Doc cards: outer wrapper (docWrapperBox+docCardVars+zIndex) → DocCard.
            DocCard's CardShell uses inWrapper=true (inset:0) so it fills the wrapper.
            The prose oversample→downscale subtree is unchanged. */}
        {cards.filter((c) => c.kind === "doc").map((c) => {
          const id = cardId(c);
          return (
            <div
              key={id}
              ref={setEl(id)}
              style={{
                position: "absolute",
                top: 0,
                left: 0,
                ...docWrapperBox(),
                ...(docCardVars(c.frame) as React.CSSProperties),
                zIndex: c.z,
              }}
            >
              <DocCard
                model={c}
                markdown={props.docContents.get(c.path) ?? ""}
                ownerName={ownerChipName(c.ownerTermId, termLabel)}
                lastChangedMs={props.docMeta.get(c.path)?.lastChangedMs}
                selected={id === props.selectedId}
                detached={docDimmed(c.ownerTermId)}
                getZoom={getZoom}
                onMove={(frame) => props.onCardMove(id, frame)}
                onMoveStart={() => props.onCardMoveStart(id)}
                onMoveEnd={() => props.onCardMoveEnd(id)}
                onResize={(frame) => props.onCardResize(id, frame)}
                onResizeEnd={() => props.onCardResizeEnd(id)}
                onGrab={() => props.onCardGrab(id)}
                onClose={() => props.onDocClose(c.path)}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}
