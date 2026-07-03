// A live HTML doc card (spec 2607.0004): the file runs as real JS inside a
// sandboxed iframe served by tarmac-card:// (opaque origin, header CSP, shim
// prepended Rust-side). Shield-by-default: a transparent overlay keeps the
// card look-don't-touch — pointer events bubble to CardShell (select/raise/
// wheel) and never reach the iframe — until a double-click borrows it. Esc
// goes home via the shim's escape relay (focus inside the iframe) or the App
// Esc ladder (focus in the host).
//
// Crispness: the iframe is laid out at real screen px (cardIframePx) with no
// transform at rest; during a pan/zoom gesture it keeps its px size under a
// temporary scale (cardGestureScale) and is re-sized once on settle — the
// terminal-canvas model, not DocCard's prose oversample→downscale (a foreign
// iframe document cannot be pre-laid-out at K×).

import { useEffect, useRef, useState } from "react";
import { CardShell } from "./CardShell";
import { cardSrcUrl } from "../kit/docKind";
import { cardIframePx, cardGestureScale } from "../kit/cardZoom";
import {
  formatCardArgs,
  parseCardMessage,
  pushCardConsole,
  type CardConsoleEntry,
} from "../kit/cardConsole";
import { RASTER_SCALE_SETTLE_MS } from "../kit/rasterScale";
import { repoColors } from "../theme";
import { recencyLabel } from "../kit/chromeText";
import type { DocCardModel, WorldFrame } from "../board/model";

/** .card-header world height (30px in card.css, zoom-scaled for doc-layer cards). */
const HEADER_H = 30;

const basename = (p: string): string => {
  const i = p.lastIndexOf("/");
  return i >= 0 ? p.slice(i + 1) : p;
};

interface HtmlCardProps {
  model: DocCardModel;
  ownerName?: string | null;
  lastChangedMs?: number;
  selected?: boolean;
  borrowed?: boolean;
  onBorrow: () => void;
  onEscapeHome: () => void;
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

export function HtmlCard(props: HtmlCardProps) {
  const { model } = props;
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const shieldRef = useRef<HTMLDivElement>(null);

  // Component-local console buffer — dies on unmount (reload loses state by
  // design); key={id} in Board keeps it stable across drags/resizes.
  const [entries, setEntries] = useState<CardConsoleEntry[]>([]);
  const [consoleOpen, setConsoleOpen] = useState(false);

  // Settled zoom drives the real-px iframe box; a gesture applies a temporary
  // scale and re-settles once after RASTER_SCALE_SETTLE_MS of stability.
  const [settledZoom, setSettledZoom] = useState(props.getZoom);
  const [gestureScale, setGestureScale] = useState(1);
  const settledZoomRef = useRef(settledZoom);
  settledZoomRef.current = settledZoom;
  const getZoomRef = useRef(props.getZoom);
  getZoomRef.current = props.getZoom;
  const borrowedRef = useRef(props.borrowed);
  borrowedRef.current = props.borrowed;
  const onEscapeHomeRef = useRef(props.onEscapeHome);
  onEscapeHomeRef.current = props.onEscapeHome;
  const onBorrowRef = useRef(props.onBorrow);
  onBorrowRef.current = props.onBorrow;

  // Shim message relay: filter to THIS card's iframe, validate, buffer.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (e.source !== iframeRef.current?.contentWindow) return;
      const msg = parseCardMessage(e.data);
      if (!msg) return;
      if (msg.kind === "escape") {
        if (borrowedRef.current) onEscapeHomeRef.current();
        return;
      }
      setEntries((buf) => pushCardConsole(buf, { level: msg.level, args: msg.args }));
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  // Zoom watcher: the board's style attr mutates every pan/zoom frame (DocCard
  // precedent); we react only to zoom changes — scale immediately, resize the
  // iframe once on settle.
  useEffect(() => {
    const el = iframeRef.current;
    if (!el) return;
    const board = el.closest(".board") as HTMLElement | null;
    if (!board) return;
    let lastZoom = getZoomRef.current();
    let timer: number | null = null;
    const mo = new MutationObserver(() => {
      const zoom = getZoomRef.current();
      if (zoom === lastZoom) return;
      lastZoom = zoom;
      setGestureScale(cardGestureScale(zoom, settledZoomRef.current));
      if (timer != null) window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        setSettledZoom(zoom);
        setGestureScale(1);
      }, RASTER_SCALE_SETTLE_MS);
    });
    mo.observe(board, { attributes: true, attributeFilter: ["style"] });
    return () => {
      mo.disconnect();
      if (timer != null) window.clearTimeout(timer);
    };
  }, []);

  // Borrow gesture: native dblclick (React synthetic timing is unreliable under
  // the board's native listeners — CardShell wheel precedent). Re-runs when the
  // shield remounts after an un-borrow.
  useEffect(() => {
    const el = shieldRef.current;
    if (!el) return;
    const onDblClick = () => onBorrowRef.current();
    el.addEventListener("dblclick", onDblClick);
    return () => el.removeEventListener("dblclick", onDblClick);
  }, [props.borrowed]);

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
  // Real-px box for the body area (frame minus the world-30px header).
  const box = cardIframePx({ w: model.frame.w, h: model.frame.h - HEADER_H }, settledZoom);

  return (
    <CardShell
      className={props.borrowed ? "html-card borrowed" : "html-card"}
      frame={model.frame}
      z={model.z}
      inWrapper
      fresh={model.fresh}
      selected={props.selected}
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
          <span className="glyph">{"</>"}</span>
          {dotColor && <span className="repo-dot" style={{ background: dotColor }} />}
          <span className="label">{basename(model.path)}</span>
          <span className="spacer" />
          {props.ownerName && <span className="owner-chip">{"← "}{props.ownerName}</span>}
          {model.fresh && <span style={{ color: "var(--agent)" }}>✚ now</span>}
          {recency && <span className="recency-meta">{recency}</span>}
          {entries.length > 0 && (
            <span
              className="console-badge"
              onPointerDown={(e) => { e.stopPropagation(); e.preventDefault(); }}
              onClick={() => setConsoleOpen((o) => !o)}
              title="Toggle console"
            >
              ⌥ {entries.length}
            </span>
          )}
          <span
            className="close"
            onPointerDown={(e) => { e.stopPropagation(); e.preventDefault(); }}
            onClick={props.onClose}
            title="Close"
          >
            ✕
          </span>
        </>
      }
    >
      <div className="html-body">
        <iframe
          ref={iframeRef}
          className="html-frame"
          sandbox="allow-scripts"
          allow=""
          src={cardSrcUrl(model.path, props.lastChangedMs)}
          style={{
            width: box.w,
            height: box.h,
            transform: gestureScale === 1 ? undefined : `scale(${gestureScale})`,
            transformOrigin: "0 0",
          }}
        />
        {/* Shield: transparent, no handlers that stop/capture — pointerdown
            bubbles to CardShell's onBodyPointerDown (select/raise) and wheel to
            its native listener; the iframe just never sees any of it. */}
        {!props.borrowed && <div className="html-shield" ref={shieldRef} />}
        {consoleOpen && (
          <div className="html-console">
            {entries.map((en, i) => (
              <div key={i} className={`html-console-line ${en.level}`}>
                {formatCardArgs(en.args)}
              </div>
            ))}
          </div>
        )}
      </div>
    </CardShell>
  );
}
