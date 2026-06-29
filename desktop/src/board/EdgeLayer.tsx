// Provenance edges: dashed lines from each terminal to its attached docs.
// Painted as an SVG in screen space; d is written imperatively by
// EdgeLayerHandle.updateEdges so the pan/zoom hot path needs zero React renders.
// React re-renders only when the edge SET changes (card add/remove/attach flip).

import React, { useRef, useImperativeHandle } from "react";
import { worldToView } from "../kit/boardTransform";
import type { CardModel } from "./model";
import type { EdgeLayerHandle } from "./BoardEngine";

export type { EdgeLayerHandle };

const center = (f: { x: number; y: number; w: number; h: number }) => ({
  x: f.x + f.w / 2,
  y: f.y + f.h / 2,
});

function edgeKeys(cards: CardModel[]): string[] {
  const terms = new Map<string, boolean>();
  for (const c of cards) if (c.kind === "term") terms.set(c.termId, true);
  const keys: string[] = [];
  for (const c of cards) {
    if (c.kind !== "doc" || !c.ownerTermId || !c.attached) continue;
    if (!terms.has(c.ownerTermId)) continue;
    keys.push(`${c.ownerTermId}->${c.path}`);
  }
  return keys;
}

export const EdgeLayer = React.forwardRef<EdgeLayerHandle, { cards: CardModel[] }>(
  function EdgeLayer({ cards }, ref) {
    const pathRefs = useRef<Map<string, SVGPathElement>>(new Map());
    const keys = edgeKeys(cards);

    useImperativeHandle(ref, () => ({
      updateEdges(cards: CardModel[], vp: { zoom: number; cx: number; cy: number }, vpRect: DOMRect) {
        const termMap = new Map<string, CardModel>();
        for (const c of cards) if (c.kind === "term") termMap.set(c.termId, c);
        const vpCenter = { x: vpRect.width / 2, y: vpRect.height / 2 };
        const vpWorld = { x: vp.cx, y: vp.cy };
        for (const c of cards) {
          if (c.kind !== "doc" || !c.ownerTermId || !c.attached) continue;
          const owner = termMap.get(c.ownerTermId);
          if (!owner) continue;
          const pathEl = pathRefs.current.get(`${c.ownerTermId}->${c.path}`);
          if (!pathEl) continue;
          const a = worldToView(center(owner.frame), vp.zoom, vpWorld, vpCenter);
          const b = worldToView(center(c.frame), vp.zoom, vpWorld, vpCenter);
          pathEl.setAttribute("d", `M ${a.x} ${a.y} L ${b.x} ${b.y}`);
        }
      },
    }));

    return (
      <svg className="edge-layer">
        {keys.map((key) => (
          <path
            key={key}
            ref={(el) => {
              if (el) pathRefs.current.set(key, el);
              else pathRefs.current.delete(key);
            }}
          />
        ))}
      </svg>
    );
  },
);
