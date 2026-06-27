// A markdown doc card. The whole frontend is already a webview, so we render
// markdown with marked.js straight into the DOM — no nested WKWebView, hence no
// about:blank suspend/restore hack. The scroll area is plain (no tabindex), so a
// click here never pulls keyboard focus off the prime terminal.
//
// Prose is laid out once at fixed base constants. The ancestor .world already
// applies transform:scale(zoom) (BoardEngine), so doc card content is visually
// scaled by zoom without any per-card scale. A static translateZ(0) on the
// .doc-prose-scaler wrapper promotes the layer so WebKit re-rasterizes crisply
// after the gesture settles. Wrap points never change → no reflow.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { marked } from "marked";
import { CardShell } from "./CardShell";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";
import { docScalerStyle } from "../kit/docZoom";
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
  // Store scroll position as a fraction (scrollTop / scrollHeight) so it can be
  // restored after content changes (live file_event re-renders).
  const savedScrollFrac = useRef(0);

  // Re-render markdown on content change, preserving scroll position (mirrors the
  // Swift doc card's scroll persistence across live file_event re-renders).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    const prev = savedScrollFrac.current;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    if (scroll.scrollHeight > scroll.clientHeight) {
      scroll.scrollTop = prev * scroll.scrollHeight;
    }
  }, [markdown]);

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
      {/* doc-scroll: card-sized scroll container (fills card-body via CSS).
          doc-prose-scaler: static layer-promotion wrapper (translateZ(0)) so
          WebKit re-rasterizes this layer crisply after the board gesture settles.
          doc-prose: fixed metrics from theme.css; never zoom-scaled inline. */}
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
        <div className="doc-prose-scaler" style={docScalerStyle()}>
          <div className="doc-prose" ref={proseRef} />
        </div>
      </div>
    </CardShell>
  );
}
