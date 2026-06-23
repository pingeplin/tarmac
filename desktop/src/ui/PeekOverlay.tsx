// The right-edge peek slide-over (port of PeekPanel.swift): a Quick-Look doc
// preview opened with ⌘P. Reuses the DocCard markdown pipeline (marked → DOM,
// scroll-preserving) and the global .doc-scroll/.doc-prose styling. ⌘⏎ / the pin
// chip pins-or-unpins; esc / the esc chip closes. Always mounted so it slides both
// ways; the `.hidden` class drives the off-screen transform. Non-focusable beyond
// text selection, so opening it never steals keyboard focus from the prime terminal.

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { marked } from "marked";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

interface PeekOverlayProps {
  visible: boolean;
  path: string | null;
  markdown: string;
  repoColor?: number;
  lastChangedMs?: number;
  onPin: () => void;
  onClose: () => void;
}

export function PeekOverlay(props: PeekOverlayProps) {
  const { visible, path, markdown } = props;
  const scrollRef = useRef<HTMLDivElement>(null);
  const proseRef = useRef<HTMLDivElement>(null);
  const savedScroll = useRef(0);
  const [, setTick] = useState(0);

  // Re-render markdown on content / path change, preserving scroll (like DocCard).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    const prev = savedScroll.current;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    scroll.scrollTop = prev;
  }, [markdown, path]);

  // The recency meta self-ticks every 1s while the panel is visible.
  useEffect(() => {
    if (!visible) return;
    const id = window.setInterval(() => setTick((n) => n + 1), 1000);
    return () => window.clearInterval(id);
  }, [visible]);

  const dotColor = props.repoColor != null ? repoColors[props.repoColor % repoColors.length] : undefined;
  const meta = visible ? recencyLabel(props.lastChangedMs, Date.now()) : null;

  return (
    <div className={`peek${visible ? "" : " hidden"}`} aria-hidden={!visible}>
      <div className="peek-header">
        {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
        <span className="peek-path">{path ? basename(path) : ""}</span>
        {meta && <span className="peek-meta">{meta}</span>}
        <span className="spacer" />
        {/* preventDefault on mousedown keeps focus on the prime terminal (the peek
            must never steal keyboard focus); onClick still fires. */}
        <button
          className="kbd-chip"
          onClick={props.onPin}
          onMouseDown={(e) => e.preventDefault()}
          tabIndex={-1}
          title="Pin / unpin (⌘⏎)"
        >
          ⌘⏎ pin
        </button>
        <button
          className="kbd-chip"
          onClick={props.onClose}
          onMouseDown={(e) => e.preventDefault()}
          tabIndex={-1}
          title="Close (esc)"
        >
          esc
        </button>
      </div>
      <div className="peek-body">
        <div
          className="doc-scroll"
          ref={scrollRef}
          onScroll={(e) => (savedScroll.current = (e.currentTarget as HTMLDivElement).scrollTop)}
        >
          <div className="doc-prose" ref={proseRef} />
        </div>
      </div>
    </div>
  );
}
