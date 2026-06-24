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

interface PeekOverlayProps {
  visible: boolean;
  path: string | null;
  displayPath: string;   // NEW — repo-qualified path, head-truncated by CSS
  markdown: string;
  repoColor?: number;
  lastChangedMs?: number;
  onPin: () => void;
  onClose: () => void;
}

export function PeekOverlay(props: PeekOverlayProps) {
  const { visible, path, displayPath, markdown } = props;
  const scrollRef = useRef<HTMLDivElement>(null);
  const proseRef = useRef<HTMLDivElement>(null);
  const savedScroll = useRef(0);
  const [tick, setTick] = useState(0);

  // Re-render markdown on content / path change, preserving scroll (like DocCard).
  useLayoutEffect(() => {
    const prose = proseRef.current;
    const scroll = scrollRef.current;
    if (!prose || !scroll) return;
    const prev = savedScroll.current;
    prose.innerHTML = marked.parse(markdown, { async: false }) as string;
    scroll.scrollTop = prev;
  }, [markdown, path]);

  // The recency meta self-ticks every 1s, but only while the panel is visible AND the
  // doc is inside the 30s recency window. Self-terminating: each tick re-runs this effect
  // (via `tick` in deps), which stops scheduling once recencyLabel lapses to null — the
  // same setTimeout-chain pattern as DocCard / Swift RecentMetaLabel. A fresh file_event
  // changes lastChangedMs and re-arms the tick.
  useEffect(() => {
    if (!visible) return;
    if (recencyLabel(props.lastChangedMs, Date.now()) === null) return;
    const id = window.setTimeout(() => setTick((n) => n + 1), 1000);
    return () => window.clearTimeout(id);
  }, [visible, props.lastChangedMs, tick]);

  const dotColor = props.repoColor != null ? repoColors[props.repoColor % repoColors.length] : undefined;
  const meta = visible ? recencyLabel(props.lastChangedMs, Date.now()) : null;

  return (
    <div className={`peek${visible ? "" : " hidden"}`} aria-hidden={!visible}>
      <div className="peek-header">
        {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
        <span className="peek-path" title={displayPath}>{displayPath}</span>
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
