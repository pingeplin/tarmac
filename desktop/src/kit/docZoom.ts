// Pure module: doc-card zoom layout — the "Panel H" oversample→downscale
// mechanism. The card box is rendered at real pixel size (card{w,h}×zoom) via a
// translate-only wrapper in .doc-layer, with NO transform scale on the box, so
// its border/clip/shadow rasterize crisply at the real pixel size. The prose is
// laid out ONCE at the K× reference (K = --oversample-k, frozen, zoom-free) and
// the bare innermost .doc-prose-scaler carries scale(zoom/K) — a pure DOWN-scale
// (≤1 across the whole zoom range), so WebKit downsamples a high-detail layer
// rather than upscaling a 1× one → crisp at every zoom, with no reflow.
//
// Pan/zoom hot path: BoardEngine writes --zoom/--world-tx/--world-ty once per
// frame; every calc() here follows for free — no per-card JS, no React re-render.
// Frame change (drag/resize/restore): React sets --card-{x,y,w,h} from frame.

export const DOC_PROSE_FONT_SIZE_PX = 14;
export const DOC_PROSE_MAX_WIDTH_PX = 720;
export const DOC_SCROLL_PADDING_V_PX = 18;
export const DOC_SCROLL_PADDING_H_PX = 22;

/** Oversample factor for the "Panel H" crisp-zoom mechanism: the prose is laid
 *  out ONCE at K× the base reference and the scaler DOWN-scales it by zoom/K, so
 *  the bare-glyph layer is never upsampled (crisp even at 1×). K MUST be ≥ the
 *  board's max zoom (BoardEngine MAX_ZOOM = 3.0) so scale(zoom/K) ≤ 1 across the
 *  whole zoom range. Kept in sync with the `--oversample-k` CSS var in theme.css. */
export const DOC_OVERSAMPLE_K = 3;

/** The ONE layout the prose is rendered at — no zoom parameter, so it is
 *  structurally impossible for sizing to depend on zoom. */
export function docProseLayout(): {
  fontSizePx: number;
  maxWidthPx: number;
  paddingVPx: number;
  paddingHPx: number;
} {
  return {
    fontSizePx: DOC_PROSE_FONT_SIZE_PX,
    maxWidthPx: DOC_PROSE_MAX_WIDTH_PX,
    paddingVPx: DOC_SCROLL_PADDING_V_PX,
    paddingHPx: DOC_SCROLL_PADDING_H_PX,
  };
}

/** Real-px box style for the per-card wrapper in .doc-layer. Width/height are
 *  card{w,h}×zoom (real pixels); transform is translate-only (NO scale). The
 *  box origin (0,0) lands at the same screen point worldToView projects the
 *  card's world origin, keeping EdgeLayer endpoints co-located at every zoom.
 *
 *  The translate is SNAPPED to whole device pixels (--device-px = 1px/dpr, written
 *  by BoardEngine.apply()). world-tx + card-x*zoom is a raw float, so unsnapped the
 *  card's raster lands on a fractional device grid and WebKit resolves it by
 *  filtering — every glyph and hairline in the card softens. Invisible at 254ppi,
 *  plainly visible at 109ppi (the board's own chrome, which has no transform, stays
 *  sharp next to it). Costs ≤0.5 device px against the EdgeLayer endpoints, which
 *  terminate at card centers behind the card. */
export function docWrapperBox(): {
  width: string;
  height: string;
  transform: string;
  transformOrigin: string;
} {
  return {
    width: "calc(var(--card-w) * var(--zoom))",
    height: "calc(var(--card-h) * var(--zoom))",
    transform:
      "translate(round(calc(var(--world-tx) + var(--card-x) * var(--zoom)),var(--device-px)),round(calc(var(--world-ty) + var(--card-y) * var(--zoom)),var(--device-px)))",
    transformOrigin: "0 0",
  };
}

/** Per-card CSS custom properties set from the committed world frame. Board
 *  spreads these onto the wrapper on every frame-changing render; the pan/zoom
 *  hot path then resolves width/height/position via calc() without JS. */
export function docCardVars({ x, y, w, h }: { x: number; y: number; w: number; h: number }): {
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

/** Inline style for the bare innermost prose-scaler — the sole scale in the
 *  subtree. The prose is laid out once at the K× reference (frozen, zoom-free,
 *  see the .doc-prose theme.css rule), so this DOWN-scales it by zoom/K: never an
 *  upsample (crisp at 1×), never a reflow (layout never references --zoom). Never
 *  will-change: that pins the raster → permanent blur. Origin 0 0 matches the box. */
export function docProseScaler(): {
  transform: string;
  transformOrigin: string;
} {
  return {
    transform: "scale(calc(var(--zoom) / var(--oversample-k)))",
    transformOrigin: "0 0",
  };
}
