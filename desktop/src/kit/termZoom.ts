// Pure module: terminal-card zoom layout — the outer wrapper is translate-only
// (identical formula to docWrapperBox); the inner box is zoom-free (var(--card-w/h))
// with a single scale(var(--zoom)) so the host never resizes on zoom → no fit()/PTY resize.

/** Real-px outer wrapper for a terminal card in .card-layer.
 *  String-for-string identical to docWrapperBox() — asserted by S1. */
export function termWrapperBox(): {
  width: string;
  height: string;
  transform: string;
  transformOrigin: string;
} {
  return {
    width: "calc(var(--card-w) * var(--zoom))",
    height: "calc(var(--card-h) * var(--zoom))",
    transform:
      "translate(calc(var(--world-tx) + var(--card-x) * var(--zoom)),calc(var(--world-ty) + var(--card-y) * var(--zoom)))",
    transformOrigin: "0 0",
  };
}

/** Per-card CSS custom properties — same shape as docCardVars(). */
export function termCardVars({ x, y, w, h }: { x: number; y: number; w: number; h: number }): {
  "--card-x": string;
  "--card-y": string;
  "--card-w": string;
  "--card-h": string;
} {
  return {
    "--card-x": `${x}px`,
    "--card-y": `${y}px`,
    "--card-w": `${w}px`,
    "--card-h": `${h}px`,
  };
}

/** Zoom-free host box: width/height are var(--card-w/h) so the host never
 *  changes size during zoom; scale(var(--zoom)) renders the terminal at the
 *  right screen size without triggering ResizeObserver / fit() / PTY resize. */
export function termInnerBox(): {
  width: string;
  height: string;
  transform: string;
  transformOrigin: string;
} {
  return {
    width: "var(--card-w)",
    height: "var(--card-h)",
    transform: "scale(var(--zoom))",
    transformOrigin: "0 0",
  };
}

/** Effective layout→screen scale at the xterm element.
 *  Docked terminals live outside the board transform — their host BCR is already
 *  in screen space, so the override must be skipped (return 1). */
export function termBcrScale(zoom: number, rs: number, docked: boolean): number {
  return docked ? 1 : zoom / rs;
}
