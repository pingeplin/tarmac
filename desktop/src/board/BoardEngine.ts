// The imperative board core. Holds the viewport (zoom + world-space center) and
// writes ONE CSS transform onto the world layer; cards are absolutely positioned
// at their world coords inside that layer, so pan/zoom is a single transform —
// never per-card reprojection, never React state on the 60fps hot path (the
// tldraw/Excalidraw pattern). React reads committed viewport changes via
// `onViewportChange` for chrome (zoom readout, minimap) only.
//
// Transform math (transform-origin 0 0): a child at world (wx,wy) lands on screen
// at (wx*zoom + Tx, wy*zoom + Ty); we want world center (cx,cy) at the viewport
// center, so Tx = W/2 - cx*zoom, Ty = H/2 - cy*zoom.

import { isCardVisible } from "../kit/cull";
import { fit } from "../kit/boardWayfinding";
import { deriveRasterScale, RASTER_SCALE_SETTLE_MS } from "../kit/rasterScale";
import type { Rect, Size } from "../kit/geom";

export interface Viewport {
  zoom: number;
  cx: number;
  cy: number;
}

/** A card the engine culls: its DOM node + current world frame. */
export interface Cullable {
  id: string;
  el: HTMLElement;
  frame: Rect;
}

// Zoom bounds match Swift Viewport (BoardModel.swift): a single 0.1..3.0 cap on
// EVERY path — pinch, ± buttons, setViewport (restore), fly, and fit — via the
// shared clamp, so the readout never exceeds 300%.
const MIN_ZOOM = 0.1;
export const MAX_ZOOM = 3.0;

// Fit-to-cards: 10% margin each side; zoom shares the engine's 0.1..3.0 clamp.
const FIT_MARGIN = 0.1;
const FIT_MIN_ZOOM = MIN_ZOOM;
const FIT_MAX_ZOOM = MAX_ZOOM;

// Fly-to viewport tween (Swift BoardView.animateViewport): ~300ms, easeInOutQuad.
const FLY_DURATION_MS = 300;
const easeInOutQuad = (t: number): number => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2);

/** Below this zoom the dot grid densifies 24px → 11px (Swift semanticZoom flip)
 * and cards bitmap-scale down. Matches Viewport.semanticZoomThreshold = 0.5. */
export const SEMANTIC_ZOOM_THRESHOLD = 0.5;
const GRID_SPACING = 24;
const GRID_SPACING_LO = 11;

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

export class BoardEngine {
  private vp: Viewport = { zoom: 1, cx: 0, cy: 0 };
  private readonly viewportEl: HTMLElement;
  private readonly worldEl: HTMLElement;
  private detachers: Array<() => void> = [];

  // Viewport culling (perf #5): the card nodes + frames, plus a per-card cache of
  // the last applied visibility so we only touch the DOM when it actually flips.
  private cullables: Cullable[] = [];
  private cullVisible = new Map<string, boolean>();

  // The in-flight viewport tween's rAF handle (flyTo); null when not animating.
  private flightRaf: number | null = null;

  // rasterScale settle: hold the last settled value and a debounce timer so
  // cards re-raster only after the zoom gesture finishes, not every frame.
  private _settledRasterScale = 1;
  private _rasterSettleTimer: ReturnType<typeof setTimeout> | null = null;

  /** Fires after every committed pan/zoom (for chrome: zoom readout, minimap). */
  onViewportChange?: (vp: Viewport) => void;

  /** Fires ~150ms after zoom settles with the derived rasterScale. Cards use this
   *  to re-raster at device resolution; they never re-derive zoom themselves. */
  onRasterScaleSettle?: (scale: number) => void;

  constructor(viewportEl: HTMLElement, worldEl: HTMLElement) {
    this.viewportEl = viewportEl;
    this.worldEl = worldEl;
    this.worldEl.style.transformOrigin = "0 0";
    this.bindGestures();
    this.apply();
  }

  get viewport(): Viewport {
    return { ...this.vp };
  }

  setViewport(vp: Viewport): void {
    this.cancelFlight(); // a programmatic jump (minimap, restore) interrupts a fly
    this.vp = { zoom: clamp(vp.zoom, MIN_ZOOM, MAX_ZOOM), cx: vp.cx, cy: vp.cy };
    this.apply();
    this.onViewportChange?.(this.viewport);
  }

  /** The visible region in WORLD coords (inverse-projected viewport bounds).
   * Drives the minimap viewport box + offscreen-hint isOffscreen test. */
  get viewportWorldRect(): Rect {
    const rect = this.viewportEl.getBoundingClientRect();
    const tl = this.viewToWorld(rect.left, rect.top);
    const br = this.viewToWorld(rect.left + rect.width, rect.top + rect.height);
    return { x: tl.x, y: tl.y, w: br.x - tl.x, h: br.y - tl.y };
  }

  /** The board's current pixel size (the offscreen-hint/stacking viewRect). */
  get viewportSize(): Size {
    const rect = this.viewportEl.getBoundingClientRect();
    return { w: rect.width, h: rect.height };
  }

  /** Fit all cards into view with a 10% margin (zoom-control ⊡), clamped to Swift's
   * 0.1..3.0; no-op with no cards. Reads fresh viewport pixel size at call time. */
  fitToCards(): void {
    if (this.cullables.length === 0) return;
    const frames = this.cullables.map((c) => c.frame);
    const f = fit(frames, this.viewportSize, FIT_MARGIN, FIT_MIN_ZOOM, FIT_MAX_ZOOM);
    if (!f) return;
    this.setViewport({ zoom: f.zoom, cx: f.center.x, cy: f.center.y });
  }

  /** Multiply zoom by `factor`, anchored at the VIEWPORT CENTER (the zoom-control
   * ± path; Swift anchors ± at the board center, not the pointer). */
  zoomByCentered(factor: number): void {
    const rect = this.viewportEl.getBoundingClientRect();
    this.zoomAt(factor, rect.left + rect.width / 2, rect.top + rect.height / 2);
  }

  /** Animate the viewport to `target` over ~300ms (easeInOutQuad), or jump instantly
   * under reduce-motion. Interrupted by any user gesture or programmatic setViewport.
   * The fly writes vp directly (not via setViewport) so it doesn't cancel itself. */
  flyTo(target: Viewport): void {
    this.cancelFlight();
    const dest: Viewport = { zoom: clamp(target.zoom, MIN_ZOOM, MAX_ZOOM), cx: target.cx, cy: target.cy };
    const reduce =
      typeof window !== "undefined" &&
      window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
    if (reduce) {
      this.setViewport(dest);
      return;
    }
    const from = { ...this.vp };
    let startTs: number | null = null;
    const step = (ts: number) => {
      if (startTs === null) startTs = ts;
      const t = Math.min(1, (ts - startTs) / FLY_DURATION_MS);
      const k = easeInOutQuad(t);
      this.vp = {
        zoom: from.zoom + (dest.zoom - from.zoom) * k,
        cx: from.cx + (dest.cx - from.cx) * k,
        cy: from.cy + (dest.cy - from.cy) * k,
      };
      this.apply();
      this.onViewportChange?.(this.viewport);
      this.flightRaf = t < 1 ? requestAnimationFrame(step) : null;
    };
    this.flightRaf = requestAnimationFrame(step);
  }

  /** Fly the viewport to center `frame` at zoom 1.0 (offscreen-hint ⏎ target). */
  flyToCard(frame: Rect): void {
    this.flyTo({ zoom: 1.0, cx: frame.x + frame.w / 2, cy: frame.y + frame.h / 2 });
  }

  private cancelFlight(): void {
    if (this.flightRaf !== null) {
      cancelAnimationFrame(this.flightRaf);
      this.flightRaf = null;
    }
  }

  /** Pan by a screen-pixel delta (two-finger scroll). */
  pan(dxScreen: number, dyScreen: number): void {
    this.cancelFlight();
    this.vp.cx -= dxScreen / this.vp.zoom;
    this.vp.cy -= dyScreen / this.vp.zoom;
    this.apply();
    this.onViewportChange?.(this.viewport);
  }

  /** Multiply zoom by `factor`, keeping the world point under (anchorX,anchorY)
   * fixed on screen (pinch / ⌘-scroll anchored at the pointer). */
  zoomAt(factor: number, anchorXScreen: number, anchorYScreen: number): void {
    this.cancelFlight();
    const rect = this.viewportEl.getBoundingClientRect();
    const ax = anchorXScreen - rect.left;
    const ay = anchorYScreen - rect.top;
    const z0 = this.vp.zoom;
    const z1 = clamp(z0 * factor, MIN_ZOOM, MAX_ZOOM);
    if (z1 === z0) return;
    // world point under the anchor before the zoom...
    const wx = (ax - rect.width / 2) / z0 + this.vp.cx;
    const wy = (ay - rect.height / 2) / z0 + this.vp.cy;
    // ...must stay under the anchor after.
    this.vp.zoom = z1;
    this.vp.cx = wx - (ax - rect.width / 2) / z1;
    this.vp.cy = wy - (ay - rect.height / 2) / z1;
    this.apply();
    this.onViewportChange?.(this.viewport);
  }

  /** Screen (client) coords → world coords. */
  viewToWorld(clientX: number, clientY: number): { x: number; y: number } {
    const rect = this.viewportEl.getBoundingClientRect();
    return {
      x: (clientX - rect.left - rect.width / 2) / this.vp.zoom + this.vp.cx,
      y: (clientY - rect.top - rect.height / 2) / this.vp.zoom + this.vp.cy,
    };
  }

  /** World coords → screen (client) coords. */
  worldToView(wx: number, wy: number): { x: number; y: number } {
    const rect = this.viewportEl.getBoundingClientRect();
    return {
      x: (wx - this.vp.cx) * this.vp.zoom + rect.width / 2 + rect.left,
      y: (wy - this.vp.cy) * this.vp.zoom + rect.height / 2 + rect.top,
    };
  }

  /** World coords → board-LOCAL coords (relative to the viewport element's
   * top-left, no client offset). The offscreen-hint overlay is inset:0 over the
   * board, so this is exactly its coordinate space. */
  worldToLocal(wx: number, wy: number): { x: number; y: number } {
    const rect = this.viewportEl.getBoundingClientRect();
    return {
      x: (wx - this.vp.cx) * this.vp.zoom + rect.width / 2,
      y: (wy - this.vp.cy) * this.vp.zoom + rect.height / 2,
    };
  }

  /** Register the cards to cull (their nodes + current world frames). Called by
   * the Board on every committed card-set/frame change — NOT per pan frame. */
  setCullables(cullables: Cullable[]): void {
    this.cullables = cullables;
    // Drop cache entries for cards that went away so the map can't leak.
    const live = new Set(cullables.map((c) => c.id));
    for (const id of this.cullVisible.keys()) {
      if (!live.has(id)) this.cullVisible.delete(id);
    }
    this.applyCull();
  }

  destroy(): void {
    this.cancelFlight();
    if (this._rasterSettleTimer !== null) {
      clearTimeout(this._rasterSettleTimer);
      this._rasterSettleTimer = null;
    }
    for (const off of this.detachers) off();
    this.detachers = [];
  }

  private apply(): void {
    const rect = this.viewportEl.getBoundingClientRect();
    const tx = rect.width / 2 - this.vp.cx * this.vp.zoom;
    const ty = rect.height / 2 - this.vp.cy * this.vp.zoom;
    this.worldEl.style.transform = `translate(${tx}px, ${ty}px) scale(${this.vp.zoom})`;
    // The infinite dot lattice reads the world origin (tx,ty) + spacing so it
    // pans/zooms WITH the content (one tiled CSS background, not N nodes —
    // carrying the perf-whiteboard-zoom lesson; the grid is constant-time). Below
    // the semantic-zoom threshold the world spacing densifies 24→11px to match
    // the Swift board's look (free here — just a background-size change).
    const worldSpacing = this.vp.zoom < SEMANTIC_ZOOM_THRESHOLD ? GRID_SPACING_LO : GRID_SPACING;
    this.viewportEl.style.setProperty("--zoom", String(this.vp.zoom));
    this.viewportEl.style.setProperty("--world-tx", `${tx}px`);
    this.viewportEl.style.setProperty("--world-ty", `${ty}px`);
    this.viewportEl.style.setProperty("--grid-size", `${worldSpacing * this.vp.zoom}px`);
    this.viewportEl.style.setProperty("--grid-x", `${tx}px`);
    this.viewportEl.style.setProperty("--grid-y", `${ty}px`);
    this.scheduleRasterSettle();
    this.applyCull(rect);
  }

  /** Debounce rasterScale settle: cheap GPU transform during the gesture, cards
   *  re-raster only after zoom is idle for RASTER_SCALE_SETTLE_MS. Idempotent —
   *  fires the callback only when the derived scale actually changes. */
  private scheduleRasterSettle(): void {
    if (this._rasterSettleTimer !== null) clearTimeout(this._rasterSettleTimer);
    const next = deriveRasterScale(this.vp.zoom);
    this._rasterSettleTimer = setTimeout(() => {
      this._rasterSettleTimer = null;
      if (next !== this._settledRasterScale) {
        this._settledRasterScale = next;
        this.onRasterScaleSettle?.(next);
      }
    }, RASTER_SCALE_SETTLE_MS);
  }

  /** Hide cards more than one viewport off-screen (visibility:hidden keeps the
   * node ALIVE — xterm keeps consuming PTY output, doc keeps scroll). Runs on the
   * pan/zoom hot path but only writes the DOM when a card's visibility flips. */
  private applyCull(rect?: DOMRect): void {
    if (this.cullables.length === 0) return;
    const r = rect ?? this.viewportEl.getBoundingClientRect();
    for (const c of this.cullables) {
      const visible = isCardVisible(c.frame, this.vp, r.width, r.height);
      if (this.cullVisible.get(c.id) === visible) continue;
      this.cullVisible.set(c.id, visible);
      c.el.style.visibility = visible ? "" : "hidden";
    }
  }

  private bindGestures(): void {
    // Browser maps trackpad pinch to ctrl+wheel; plain wheel is two-finger scroll.
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      if (e.ctrlKey) {
        // Pinch zoom, anchored at the pointer. deltaY<0 = zoom in.
        const factor = Math.exp(-e.deltaY * 0.01);
        this.zoomAt(factor, e.clientX, e.clientY);
      } else {
        this.pan(-e.deltaX, -e.deltaY);
      }
    };
    this.viewportEl.addEventListener("wheel", onWheel, { passive: false });
    this.detachers.push(() => this.viewportEl.removeEventListener("wheel", onWheel));

    // A window/viewport resize changes the world transform origin (W/2,H/2), the
    // grid offset, and the cull bounds — none of which the pan/zoom path sees. Re-
    // apply on resize so the grid stays aligned and culling uses fresh dimensions
    // (matching the Swift board reprojecting on layout), not just on the next pan.
    const ro = new ResizeObserver(() => {
      this.apply();
      // A resize moves the world rect / grid origin without a pan/zoom — notify
      // chrome (minimap, offscreen hints, zoom readout) so it re-derives.
      this.onViewportChange?.(this.viewport);
    });
    ro.observe(this.viewportEl);
    this.detachers.push(() => ro.disconnect());
  }
}
