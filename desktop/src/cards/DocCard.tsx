// A markdown doc card. The whole frontend is already a webview, so we render
// markdown with marked.js straight into the DOM — no nested WKWebView, hence no
// about:blank suspend/restore hack. The scroll area is plain (no tabindex), so a
// click here never pulls keyboard focus off the prime terminal.
//
// rasterScale counter-scale: when rasterScale > 1, doc-scroll is rendered at
// rasterScale× its card size and counter-scaled back with transform:scale(1/rs).
// The doc-prose inside also has fontSize and maxWidth scaled by the same factor,
// so wrap points are provably identical before and after — no reflow. The visual
// scroll speed tracks at (deltaY / rs) × zoom screen pixels; since rs ≈ zoom at
// settle time, scroll speed in screen pixels remains essentially unchanged.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { marked } from "marked";
import { CardShell } from "./CardShell";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";
import type { DocCardModel, WorldFrame } from "../board/model";

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

// Base prose style constants (must match .doc-prose in theme.css).
const PROSE_FONT_SIZE_PX = 14;
const PROSE_MAX_WIDTH_PX = 720;
// doc-scroll padding (theme.css: padding: 18px 22px).
const SCROLL_PADDING_V_PX = 18;
const SCROLL_PADDING_H_PX = 22;

interface DocCardProps {
  model: DocCardModel;
  markdown: string;
  ownerName?: string | null;     // NEW — owner-chip label (without "← "), or null/undefined => hidden
  lastChangedMs?: number;        // NEW — real edit time for "✎ Ns"
  selected?: boolean;
  detached?: boolean;
  getZoom: () => number;
  /** Settled rasterScale from BoardEngine; 1 at rest, > 1 after zoom settles. */
  rasterScale: number;
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
  // Store scroll position as a VISUAL fraction (scrollTop / scrollHeight) so that
  // when rasterScale changes (scaling the scroll container), the visual position is
  // preserved. A raw layout scrollTop would drift by rasterScale on each settle.
  const savedScrollFrac = useRef(0);

  // Re-render markdown on content change, preserving scroll position (mirrors the
  // Swift doc card's scroll persistence across live file_event re-renders).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    // Restore visual fraction → layout scrollTop = frac × scrollHeight.
    const prev = savedScrollFrac.current;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = prev * scroll.scrollHeight;
    }
  }, [markdown]);

  // When rasterScale changes, re-apply the saved visual scroll fraction so the
  // prose doesn't jump (layout scrollTop must scale with the container).
  useLayoutEffect(() => {
    const scroll = scrollRef.current;
    if (!scroll) return;
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = savedScrollFrac.current * scroll.scrollHeight;
    }
  }, [props.rasterScale]);

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
  const rs = props.rasterScale;

  return (
    <CardShell
      className="doc-card"
      frame={model.frame}
      z={model.z}
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
      {/* doc-raster-clip: clips the over-sized scroll container when rs > 1.
          doc-scroll: the actual scroll container, rendered at rs× its card size
          then counter-scaled back to the original visual footprint via
          transform:scale(1/rs). Every dimension scales by the same factor so
          wrap points are provably identical → no reflow. At rs=1 the inline
          styles are all identity values and no transform is applied. */}
      <div className="doc-raster-clip">
        <div
          className="doc-scroll"
          ref={scrollRef}
          style={{
            width: `${rs * 100}%`,
            height: `${rs * 100}%`,
            padding: `${SCROLL_PADDING_V_PX * rs}px ${SCROLL_PADDING_H_PX * rs}px`,
            transform: rs !== 1 ? `scale(${1 / rs})` : undefined,
            transformOrigin: rs !== 1 ? "0 0" : undefined,
          }}
          onScroll={(e) => {
            const el = e.currentTarget as HTMLDivElement;
            // Save as visual fraction so restoring across rasterScale changes
            // keeps the same visual position in the document.
            savedScrollFrac.current =
              el.scrollHeight > el.clientHeight
                ? el.scrollTop / el.scrollHeight
                : 0;
          }}
        >
          <div
            className="doc-prose"
            ref={proseRef}
            style={{
              fontSize: `${PROSE_FONT_SIZE_PX * rs}px`,
              maxWidth: `${PROSE_MAX_WIDTH_PX * rs}px`,
            }}
          />
        </div>
      </div>
    </CardShell>
  );
}
