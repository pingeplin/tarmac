// A markdown doc card. The whole frontend is already a webview, so we render
// markdown with marked.js straight into the DOM — no nested WKWebView, hence no
// about:blank suspend/restore hack. The scroll area is plain (no tabindex), so a
// click here never pulls keyboard focus off the prime terminal.
//
// The card renders in .doc-layer via a real-px-sized wrapper (Panel H): the
// wrapper is sized at card{w,h}×zoom with NO transform scale, so its
// border/clip/shadow rasterize crisply at real pixel size. The prose is laid out
// ONCE at the K× reference (frozen, zoom-free — see .doc-prose in theme.css) and
// the bare innermost .doc-prose-scaler carries scale(zoom/K), a pure DOWN-scale
// (≤1) → WebKit downsamples a high-detail layer, crisp at every zoom, no reflow.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { marked } from "marked";
import { CardShell } from "./CardShell";
import { docProseScaler, DOC_OVERSAMPLE_K } from "../kit/docZoom";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";
import type { DocCardModel, WorldFrame } from "../board/model";

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

interface DocCardProps {
  model: DocCardModel;
  markdown: string;
  ownerName?: string | null;
  lastChangedMs?: number;
  selected?: boolean;
  detached?: boolean;
  getZoom: () => number;
  rootRef?: (el: HTMLDivElement | null) => void;
  onMove: (frame: WorldFrame) => void;
  onMoveStart?: () => void;
  onMoveEnd?: () => void;
  onResize?: (frame: WorldFrame) => void;
  onResizeEnd?: () => void;
  onGrab: () => void;
  onClose: () => void;
}

export function DocCard(props: DocCardProps) {
  const { model, markdown } = props;
  const scrollRef = useRef<HTMLDivElement>(null);
  const proseRef = useRef<HTMLDivElement>(null);
  const sizerRef = useRef<HTMLDivElement>(null);
  // Store scroll position as a fraction (scrollTop / scrollHeight) so it can be
  // restored after content changes (live file_event re-renders).
  const savedScrollFrac = useRef(0);
  // K× natural prose height — captured after innerHTML set, before any scale.
  const proseNatH = useRef(0);
  // Last observed zoom — used by MutationObserver to skip pan-only board frames.
  const lastZoom = useRef(props.getZoom());
  // Stable accessor ref so the mount-only effect always calls the latest getZoom.
  const getZoomRef = useRef(props.getZoom);
  getZoomRef.current = props.getZoom;

  // Size the NON-transformed sizer to the visual height so .doc-scroll.scrollHeight
  // reflects visible content rather than the un-scaled K× layout (fixes BUG A).
  // The sizer (not the transformed scaler) carries the clip, so width is never
  // cropped to the zoom/K fraction. Re-apply saved scroll fraction so position
  // survives zoom changes (fixes BUG B).
  function relayout() {
    const sizer = sizerRef.current;
    const scroll = scrollRef.current;
    if (!sizer || !scroll) return;
    const zoom = getZoomRef.current();
    sizer.style.height = Math.ceil(proseNatH.current * zoom / DOC_OVERSAMPLE_K) + "px";
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = savedScrollFrac.current * scroll.scrollHeight;
    }
  }
  // Keep a stable ref so the mount-only effect closure always calls the latest body.
  const relayoutRef = useRef(relayout);
  relayoutRef.current = relayout;

  // Re-render markdown on content change, preserving scroll position (mirrors the
  // Swift doc card's scroll persistence across live file_event re-renders).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    proseNatH.current = prose.offsetHeight;
    relayout();
  }, [markdown]);

  // Mount-only: MutationObserver on .board style fires on every pan/zoom frame;
  // we guard with lastZoom so only actual zoom changes trigger relayout. The
  // ResizeObserver re-measures proseNatH when the card is resized (re-wrap).
  useEffect(() => {
    const scroll = scrollRef.current;
    const prose = proseRef.current;
    if (!scroll || !prose) return;

    const board = scroll.closest(".board") as HTMLElement | null;
    const mo = board
      ? new MutationObserver(() => {
          const zoom = getZoomRef.current();
          if (zoom === lastZoom.current) return;
          lastZoom.current = zoom;
          relayoutRef.current();
        })
      : null;
    if (board && mo) {
      mo.observe(board, { attributes: true, attributeFilter: ["style"] });
    }

    const ro = new ResizeObserver(() => {
      if (!proseRef.current) return;
      proseNatH.current = proseRef.current.offsetHeight;
      relayoutRef.current();
    });
    ro.observe(prose);

    return () => {
      mo?.disconnect();
      ro.disconnect();
    };
  }, []);

  // 1Hz tick, only while inside the 30s window. When recencyLabel goes null we early-
  // return (schedule nothing) so a stale doc stops re-rendering; a fresh file_event
  // changes lastChangedMs, re-running this effect and restarting the tick.
  const [recencyTick, setRecencyTick] = useState(0);
  useEffect(() => {
    if (props.lastChangedMs === undefined) return;
    if (recencyLabel(props.lastChangedMs, Date.now()) === null) return;
    const id = window.setTimeout(() => setRecencyTick((n) => n + 1), 1000);
    return () => window.clearTimeout(id);
  }, [props.lastChangedMs, recencyTick]);
  const recency =
    props.lastChangedMs !== undefined ? recencyLabel(props.lastChangedMs, Date.now()) : null;

  const dotColor = model.repoColor != null ? repoColors[model.repoColor % repoColors.length] : undefined;

  return (
    <CardShell
      className="doc-card"
      frame={model.frame}
      z={model.z}
      inWrapper
      fresh={model.fresh}
      selected={props.selected}
      detached={props.detached}
      hasClose
      getZoom={props.getZoom}
      rootRef={props.rootRef}
      onMove={props.onMove}
      onMoveStart={props.onMoveStart}
      onMoveEnd={props.onMoveEnd}
      onResize={props.onResize}
      onResizeEnd={props.onResizeEnd}
      onGrab={props.onGrab}
      header={
        <>
          <span className="glyph">¶</span>
          {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
          <span className="label">{basename(model.path)}</span>
          <span className="spacer" />
          {props.ownerName && <span className="owner-chip">{"← "}{props.ownerName}</span>}
          {model.fresh && <span style={{ color: "var(--agent)" }}>✚ now</span>}
          {recency && <span className="recency-meta">{recency}</span>}
          <span className="close" onClick={props.onClose} title="Close">
            ✕
          </span>
        </>
      }
    >
      {/* doc-scroll: fills card body, no transform, no padding (padding lives on
          .doc-prose at calc(base * --oversample-k)). doc-prose-sizer: NON-transformed
          clip box whose height relayout() sets to the visual height (proseNatH ×
          zoom/K) so scrollHeight tracks visible content and the K× overhang is
          clipped in real-px space. doc-prose-scaler: the sole scale layer — carries
          scale(zoom/K), a down-scale of the frozen K× prose → crisp, reflow-free. */}
      <div
        className="doc-scroll"
        ref={scrollRef}
        onScroll={(e) => {
          const el = e.currentTarget as HTMLDivElement;
          savedScrollFrac.current =
            el.scrollHeight > el.clientHeight
              ? el.scrollTop / el.scrollHeight
              : 0;
        }}
      >
        <div className="doc-prose-sizer" ref={sizerRef}>
          <div className="doc-prose-scaler" style={docProseScaler()}>
            <div className="doc-prose" ref={proseRef} />
          </div>
        </div>
      </div>
    </CardShell>
  );
}
