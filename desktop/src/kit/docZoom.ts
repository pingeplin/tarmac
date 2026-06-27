// Pure module: doc-card zoom layout. DocCard renders prose at these fixed
// constants; the ancestor .world transform (= board zoom) provides the visual
// scale. No per-card scale transform is used — adding one would compose with
// the ancestor to produce zoom², which is geometrically wrong.

export const DOC_PROSE_FONT_SIZE_PX = 14;
export const DOC_PROSE_MAX_WIDTH_PX = 720;
export const DOC_SCROLL_PADDING_V_PX = 18;
export const DOC_SCROLL_PADDING_H_PX = 22;

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

/** The prose-subtree wrapper style: a STATIC compositing-layer hint,
 *  ZOOM-INDEPENDENT (takes no zoom argument). transform = "translateZ(0)"
 *  (layer promotion, NOT a visual scale — the ancestor .world supplies the
 *  zoom). origin "0 0".
 *  will-change is forbidden: it pins the layer raster at 1× → permanent blur
 *  under board zoom. A static translateZ(0) promotes without pinning. */
export function docScalerStyle(): { transform: string; transformOrigin: string } {
  return {
    transform: "translateZ(0)",
    transformOrigin: "0 0",
  };
}
