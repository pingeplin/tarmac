// A markdown doc card. The whole frontend is already a webview, so we render
// markdown with marked.js straight into the DOM — no nested WKWebView, hence no
// about:blank suspend/restore hack. The scroll area is plain (no tabindex), so a
// click here never pulls keyboard focus off the prime terminal.

import { useLayoutEffect, useRef } from "react";
import { marked } from "marked";
import { CardShell } from "./CardShell";
import { repoColors } from "../theme";
import type { DocCardModel, WorldFrame } from "../board/model";

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

interface DocCardProps {
  model: DocCardModel;
  markdown: string;
  getZoom: () => number;
  onMove: (frame: WorldFrame) => void;
  onGrab: () => void;
  onClose: () => void;
}

export function DocCard(props: DocCardProps) {
  const { model, markdown } = props;
  const scrollRef = useRef<HTMLDivElement>(null);
  const proseRef = useRef<HTMLDivElement>(null);
  const savedScroll = useRef(0);

  // Re-render markdown on content change, preserving scroll position (mirrors the
  // Swift doc card's scroll persistence across live file_event re-renders).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    const prev = savedScroll.current;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    scroll.scrollTop = prev;
  }, [markdown]);

  const dotColor = model.repoColor != null ? repoColors[model.repoColor % repoColors.length] : undefined;

  return (
    <CardShell
      className="doc-card"
      frame={model.frame}
      fresh={model.fresh}
      getZoom={props.getZoom}
      onMove={props.onMove}
      onGrab={props.onGrab}
      header={
        <>
          <span className="glyph">¶</span>
          {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
          <span className="label">{basename(model.path)}</span>
          <span className="spacer" />
          {model.fresh && <span style={{ color: "var(--agent)" }}>✚ now</span>}
          <span className="close" onClick={props.onClose} title="Close">
            ✕
          </span>
        </>
      }
    >
      <div
        className="doc-scroll"
        ref={scrollRef}
        onScroll={(e) => (savedScroll.current = (e.currentTarget as HTMLDivElement).scrollTop)}
      >
        <div className="doc-prose" ref={proseRef} />
      </div>
    </CardShell>
  );
}
