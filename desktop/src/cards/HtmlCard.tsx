// A live HTML doc card (spec 2607.0004): the file runs as real JS inside a
// sandboxed iframe served by tarmac-card:// (opaque origin, header CSP, shim
// prepended Rust-side). Shield-by-default: a transparent overlay keeps the
// card look-don't-touch — pointer events bubble to CardShell (select/raise/
// wheel) and never reach the iframe — until a double-click borrows it. Esc
// goes home via the shim's escape relay (focus inside the iframe) or the App
// Esc ladder (focus in the host).
//
// Crispness, two modes. MAGNIFY (the default): the document is laid out ONCE at
// root zoom MAGNIFY_K inside a frame×K box, and board zoom is carried entirely by
// scale(--zoom / K) — pure CSS, so no JS runs on the zoom path and no wrap point
// can move. REVEAL (opt-in via <meta name="tarmac-zoom" content="reveal">): the
// iframe is laid out at real screen px (cardIframePx) with no transform at rest,
// takes a temporary scale during a gesture, and is re-sized once on settle — the
// terminal-canvas model. Neither is DocCard's prose oversample→downscale: a
// foreign iframe document cannot be pre-laid-out by the host.

import { useCallback, useEffect, useRef, useState } from "react";
import { CardShell } from "./CardShell";
import { CardHeader } from "./CardHeader";
import { cardSrcUrl } from "../kit/docKind";
import { cardIframePx, cardGestureScale, cardScrollDelta, MAGNIFY_K } from "../kit/cardZoom";
import {
  formatCardArgs,
  parseCardMessage,
  pushCardConsole,
  type CardConsoleEntry,
} from "../kit/cardConsole";
import { readyActions, type ZoomMode } from "../kit/zoomMode";
import { cullPayload } from "../kit/cardCull";
import { RASTER_SCALE_SETTLE_MS } from "../kit/rasterScale";
import { CARD_HEADER_H_PX } from "../kit/termZoom";
import { basename } from "../kit/docStore";
import type { DocCardModel, WorldFrame } from "../board/model";

/** Magnify's whole zoom path: the frozen-K layout, down-scaled to the live board
 *  zoom by the compositor. No React, no observer, no per-frame work. */
const MAGNIFY_TRANSFORM = `scale(calc(var(--zoom) / ${MAGNIFY_K}))`;

interface HtmlCardProps {
  model: DocCardModel;
  ownerName?: string | null;
  lastChangedMs?: number;
  onRefresh?: () => void;
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
  /** Subscribe to this card's cull flips (spec 2609.0002); returns the
   *  unregister. Board binds the card id, so none leaks into this component. */
  onCullRegister?: (fn: (culled: boolean) => void) => () => void;
}

export function HtmlCard(props: HtmlCardProps) {
  const { model } = props;
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const shieldRef = useRef<HTMLDivElement>(null);

  // Component-local console buffer — dies on unmount (reload loses state by
  // design); key={id} in Board keeps it stable across drags/resizes.
  const [entries, setEntries] = useState<CardConsoleEntry[]>([]);
  const [consoleOpen, setConsoleOpen] = useState(false);

  // REVEAL only: settled zoom drives the real-px iframe box, and a gesture applies
  // a temporary scale that re-settles after RASTER_SCALE_SETTLE_MS of stability.
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

  // Culled state for THIS card (spec 2609.0002). Held in a ref and posted from
  // two places covering disjoint cases: the listener below (every flip once the
  // document is live) and the ready handler (the state a document is BORN into —
  // a post issued before the new document commits lands on the outgoing
  // about:blank window and is dropped).
  const culledRef = useRef(false);

  const postCull = useCallback((culled: boolean) => {
    iframeRef.current?.contentWindow?.postMessage(cullPayload(culled), "*");
  }, []);

  // Register for this card's cull flips. Child effects run before the parent's,
  // so this is in place before Board hands the engine its first cullables.
  useEffect(() => {
    const register = props.onCullRegister;
    if (!register) return;
    return register((culled) => {
      culledRef.current = culled;
      postCull(culled);
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The zoom mode in force for the CURRENT document load (spec 2607.0006,
  // 2609.0003). ONE ref, not a boolean guard beside a mode: "has a genuine ready
  // been honored" and "which mode won" are the same fact, and two of them could
  // drift. null = no ready honored yet, which is what keeps a forged repeat inert
  // (S17). The mode is also state because the render branches on it; both are
  // written at the same two sites, so a message arriving before React re-renders
  // still reads the mode actually adopted.
  const loadModeRef = useRef<ZoomMode | null>(null);
  const [magnify, setMagnify] = useState(false);
  // Reset on reload (?v= bump) so a dropped meta tag can't leak the old mode
  // forward, and the reveal box resets with it (its settled zoom went stale while
  // magnify held the zoom path). A self-reload does NOT arrive here — same src,
  // same mtime — which is the whole of #99.
  useEffect(() => {
    loadModeRef.current = null;
    setMagnify(false);
    setSettledZoom(getZoomRef.current());
    setGestureScale(1);
  }, [props.lastChangedMs]);

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
      if (msg.kind === "ready") {
        // Unconditional and first: every generation of a self-reloading document
        // must be told the state it is born into, and the payload is a state, so
        // re-asserting it costs nothing (spec 2609.0002).
        postCull(culledRef.current);
        // The verdict is applied verbatim — every branch lives in readyActions,
        // which is the only side a unit test can reach.
        const act = readyActions(loadModeRef.current, msg.meta);
        if (act.zoomPost) {
          // Frozen K, not the live board zoom: the document lays out once at this
          // factor and the outer scale(zoom/K) carries every board zoom after.
          // Re-posting per SETTLE is what re-wrapped the text (ffddbfa) — this
          // re-posts per genuine ready, which is a constant and cannot re-wrap.
          iframeRef.current?.contentWindow?.postMessage(act.zoomPost, "*");
        }
        // declared and effective can no longer disagree — the capability probe
        // that split them died with the macOS 26 floor (#94). Both halves stay
        // because the line's job is to say what mode is in force for a document
        // whose meta may be a typo, and `declared` is the resolved value, not
        // the raw string.
        if (act.logMode) {
          setEntries((buf) =>
            pushCardConsole(buf, {
              level: "info",
              args: [`zoom-mode declared=${act.declared} effective=${act.declared}`],
            }),
          );
        }
        if (act.adopt) {
          loadModeRef.current = act.adopt;
          setMagnify(act.adopt === "magnify");
        }
        return;
      }
      setEntries((buf) => pushCardConsole(buf, { level: msg.level, args: msg.args }));
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  // Zoom watcher, REVEAL only: the board's style attr mutates every pan/zoom frame
  // (DocCard precedent); we react only to zoom changes — scale immediately, resize
  // the iframe once on settle. Magnify needs none of it (MAGNIFY_TRANSFORM does the
  // whole job in CSS), so it disconnects the observer rather than re-rendering the
  // card on every frame of every gesture.
  useEffect(() => {
    if (magnify) return;
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
  }, [magnify]);

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

  // Wheel relay. On a selected card CardShell stops the wheel from panning the
  // board, and the shield above the iframe has nothing to scroll — so scrolling
  // a shielded HTML card did nothing at all. Reading is not the "touch" the
  // shield blocks, so forward the delta to the document instead. Only while
  // selected (an unselected card still pans the board) and only when the shield
  // is up (once borrowed the iframe gets the wheel natively). ctrl+wheel is
  // pinch and always belongs to the board.
  useEffect(() => {
    const el = shieldRef.current;
    if (!el || !props.selected) return;
    const onWheel = (e: WheelEvent) => {
      if (e.ctrlKey) return;
      const zoom = getZoomRef.current();
      iframeRef.current?.contentWindow?.postMessage(
        {
          tarmac: "scroll",
          dx: cardScrollDelta(e.deltaX, zoom, magnify),
          dy: cardScrollDelta(e.deltaY, zoom, magnify),
        },
        "*",
      );
    };
    el.addEventListener("wheel", onWheel, { passive: true });
    return () => el.removeEventListener("wheel", onWheel);
  }, [props.selected, props.borrowed, magnify]);

  // Body-area box (frame minus the header). Reveal sizes it in real screen px and
  // re-sizes on settle; magnify sizes it once at K and lets MAGNIFY_TRANSFORM do
  // the rest, so nothing about the box depends on board zoom.
  const box = cardIframePx(
    { w: model.frame.w, h: model.frame.h - CARD_HEADER_H_PX },
    magnify ? MAGNIFY_K : settledZoom,
  );

  return (
    <CardShell
      className={props.borrowed ? "html-card borrowed" : "html-card"}
      frame={model.frame}
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
        <CardHeader
          glyph="</>"
          repoColor={model.repoColor}
          label={basename(model.path)}
          ownerName={props.ownerName}
          fresh={model.fresh}
          lastChangedMs={props.lastChangedMs}
          onRefresh={props.onRefresh}
          onClose={props.onClose}
        >
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
        </CardHeader>
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
            transform: magnify
              ? MAGNIFY_TRANSFORM
              : gestureScale === 1
                ? undefined
                : `scale(${gestureScale})`,
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
