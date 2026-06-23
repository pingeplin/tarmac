// The bottom-left zoom control (port of ZoomControl.swift): − / readout / + / ⊡ fit.
// The ± buttons zoom anchored at the board center; fit frames all cards. The
// readout reflects the live viewport zoom. Purely presentational over 3 callbacks.

import { formatZoomPct } from "../kit/chromeText";

interface ZoomControlProps {
  zoom: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFit: () => void;
}

// Keep keyboard focus on the prime terminal: preventDefault on mousedown stops the
// button from taking focus while still firing onClick (design principle #2).
const keepFocus = (e: React.MouseEvent) => e.preventDefault();

export function ZoomControl({ zoom, onZoomIn, onZoomOut, onFit }: ZoomControlProps) {
  return (
    // Swallow the press so a click in the corner never starts a board gesture.
    <div className="zoom-control" onPointerDown={(e) => e.stopPropagation()}>
      <button className="zoom-seg" onClick={onZoomOut} onMouseDown={keepFocus} tabIndex={-1} title="Zoom out">
        −
      </button>
      <span className="zoom-sep" />
      <div className="zoom-pct">{formatZoomPct(zoom)}</div>
      <span className="zoom-sep" />
      <button className="zoom-seg" onClick={onZoomIn} onMouseDown={keepFocus} tabIndex={-1} title="Zoom in">
        +
      </button>
      <span className="zoom-sep" />
      <button className="zoom-seg" onClick={onFit} onMouseDown={keepFocus} tabIndex={-1} title="Fit to cards">
        ⊡ fit
      </button>
    </div>
  );
}
