// Dashed provenance edges: from each terminal to the docs it opened (DocOpened.
// term_id). Rendered as an SVG inside the world layer, so the edges live in world
// coordinates and pan/zoom with the cards. A 0×0 svg with overflow visible lets
// paths drawn at world coords show through.

import type { CardModel } from "./model";

const center = (f: { x: number; y: number; w: number; h: number }) => ({
  x: f.x + f.w / 2,
  y: f.y + f.h / 2,
});

export function EdgeLayer({ cards }: { cards: CardModel[] }) {
  const terms = new Map<string, CardModel>();
  for (const c of cards) if (c.kind === "term") terms.set(c.termId, c);

  const edges: Array<{ key: string; d: string }> = [];
  for (const c of cards) {
    // One provenance edge per ATTACHED doc → its owner terminal; a detached
    // (loose) doc severed the gravity tie, so its edge is dropped (Swift parity).
    if (c.kind !== "doc" || !c.ownerTermId || !c.attached) continue;
    const owner = terms.get(c.ownerTermId);
    if (!owner) continue;
    const a = center(owner.frame);
    const b = center(c.frame);
    edges.push({ key: `${c.ownerTermId}->${c.path}`, d: `M ${a.x} ${a.y} L ${b.x} ${b.y}` });
  }

  return (
    <svg className="edge-layer">
      {edges.map((e) => (
        <path key={e.key} d={e.d} />
      ))}
    </svg>
  );
}
