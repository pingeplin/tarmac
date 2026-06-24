// The shelf: a fixed top-left overlay of chips for docs parked off the board
// (port of ShelfView.swift, trimmed for the slice). A chip click brings the doc
// back to the board at the next free slot; a chip drag lands it at the drop point.
// The overlay floats over the board but is laid out in window space, so the chip's
// drop point is a client coordinate the board converts to world space.

import { useRef } from "react";
import { repoColors } from "../theme";

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

interface ShelfOverlayProps {
  paths: string[];
  repoColorFor: (path: string) => number | undefined;
  /** Pure click on a shelf chip opens the ⌘P peek for that doc. */
  onPeek: (path: string) => void;
  /** Restore a shelved doc — `drop` is the client point for a drag, omitted for a click. */
  onRestore: (path: string, drop?: { clientX: number; clientY: number }) => void;
}

export function ShelfOverlay({ paths, repoColorFor, onPeek, onRestore }: ShelfOverlayProps) {
  if (paths.length === 0) return null;
  return (
    <div className="shelf">
      <span className="shelf-label">SHELF</span>
      {paths.map((p) => (
        <ShelfChip key={p} path={p} colorIndex={repoColorFor(p)} onPeek={onPeek} onRestore={onRestore} />
      ))}
    </div>
  );
}

interface ShelfChipProps {
  path: string;
  colorIndex?: number;
  onPeek: (path: string) => void;
  onRestore: (path: string, drop?: { clientX: number; clientY: number }) => void;
}

const DRAG_THRESHOLD = 3;

function ShelfChip({ path, colorIndex, onPeek, onRestore }: ShelfChipProps) {
  const start = useRef<{ x: number; y: number } | null>(null);
  const moved = useRef(false);
  const dot = colorIndex != null ? repoColors[colorIndex % repoColors.length] : undefined;

  return (
    <div
      className="shelf-chip"
      onPointerDown={(e) => {
        (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
        start.current = { x: e.clientX, y: e.clientY };
        moved.current = false;
      }}
      onPointerMove={(e) => {
        const s = start.current;
        if (s && (Math.abs(e.clientX - s.x) > DRAG_THRESHOLD || Math.abs(e.clientY - s.y) > DRAG_THRESHOLD)) {
          moved.current = true;
        }
      }}
      onPointerUp={(e) => {
        const s = start.current;
        start.current = null;
        if (s) (e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
        if (moved.current) {
          onRestore(path, { clientX: e.clientX, clientY: e.clientY });
        } else {
          onPeek(path);
        }
        moved.current = false;
      }}
    >
      {dot && <span className="repo-dot" style={{ background: dot }} />}
      <span className="shelf-chip-name">{basename(path)}</span>
    </div>
  );
}
