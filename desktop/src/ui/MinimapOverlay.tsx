// The bottom-right minimap (port of Minimap.swift): every card as a rect plus the
// viewport box, mapped into a 132×88 pane via the already-ported MinimapMapping; a
// click re-centers the viewport on the clicked world point. Rects are drawn as
// SVG with fills from theme.ts (SVG/<canvas> can't read CSS custom properties).

import { useRef } from "react";
import { boundingBox, minimapMapping } from "../kit/boardWayfinding";
import { palette } from "../theme";
import type { Rect } from "../kit/geom";

const MAP_W = 132;
const MAP_H = 88;
const PAD = 6;

export type MinimapSignal = "none" | "live" | "bell";
export interface MinimapItem {
  worldRect: Rect;
  signal: MinimapSignal;
}

interface MinimapOverlayProps {
  items: MinimapItem[];
  viewportWorldRect: Rect;
  onJump: (world: { x: number; y: number }) => void;
}

const cardFill = (s: MinimapSignal): string =>
  s === "live" ? palette.minimapCardLive : s === "bell" ? palette.minimapCardBell : palette.bg3;

export function MinimapOverlay({ items, viewportWorldRect, onJump }: MinimapOverlayProps) {
  const ref = useRef<HTMLDivElement>(null);

  // Union the card rects WITH the viewport rect so the viewport box stays visible
  // even when panned past every card (Swift recomputeMapping).
  const worldBox = boundingBox([...items.map((i) => i.worldRect), viewportWorldRect]);
  const mapping = worldBox ? minimapMapping(worldBox, { w: MAP_W, h: MAP_H }, PAD) : null;
  const vp = mapping ? mapping.toMinimapRect(viewportWorldRect) : null;

  const onClick = (e: React.MouseEvent) => {
    if (!mapping || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    onJump(mapping.toWorld({ x: e.clientX - r.left, y: e.clientY - r.top }));
  };

  return (
    <div className="minimap" ref={ref} onClick={onClick}>
      {mapping && (
        <svg width={MAP_W} height={MAP_H} viewBox={`0 0 ${MAP_W} ${MAP_H}`}>
          {items.map((it, i) => {
            const r = mapping.toMinimapRect(it.worldRect);
            return (
              <rect
                key={i}
                x={r.x}
                y={r.y}
                width={Math.max(0, r.w)}
                height={Math.max(0, r.h)}
                rx={1.5}
                ry={1.5}
                fill={cardFill(it.signal)}
              />
            );
          })}
          {vp && (
            // 0.5px inset so the 1px stroke lands fully inside the box (Swift).
            <rect
              x={vp.x + 0.5}
              y={vp.y + 0.5}
              width={Math.max(0, vp.w - 1)}
              height={Math.max(0, vp.h - 1)}
              rx={2}
              ry={2}
              fill={palette.agentDim}
              stroke={palette.agent}
              strokeWidth={1}
            />
          )}
        </svg>
      )}
    </div>
  );
}
