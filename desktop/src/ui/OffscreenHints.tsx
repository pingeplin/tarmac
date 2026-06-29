// The offscreen-signal hint pills (port of OffscreenHints.swift): one click-through
// pill per offscreen signalling card, pinned to the edge toward it (arrow + label).
// Pure render over a pre-stacked PlacedPill[]; priority/target-selection and the
// ⏎ fly live in App (the overlay never takes the mouse — pointer-events:none).

import type { PlacedPill } from "../kit/offscreenHints";

interface OffscreenHintsProps {
  pills: PlacedPill[];
}

export function OffscreenHints({ pills }: OffscreenHintsProps) {
  if (pills.length === 0) return null;
  return (
    <div className="offscreen-hints">
      {pills.map((p) => (
        <div key={p.cardId} className={`offscreen-hint ${p.signal}`} style={{ left: p.left, top: p.top }}>
          <span className="arrow">{p.arrow}</span>
          <span className="label">{p.label}</span>
        </div>
      ))}
    </div>
  );
}
