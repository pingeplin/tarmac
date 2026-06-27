// A live terminal card: hosts an xterm.js instance, streams PTY output in over a
// binary Channel, sends keystrokes/resizes out via invoke. The board's CSS zoom
// transform scales the whole card as a bitmap (matching the Swift bitmap-scale of
// SwiftTerm layers); xterm is only ever re-measured by `fit()` on a real layout
// resize — driven by a ResizeObserver, which does NOT fire on CSS transforms.
// Selection coord correction is via a getBoundingClientRect() override on host.
//
// The xterm host node is created ONCE imperatively (useState lazy init) and
// reparented via appendChild — React never owns it as a child — so the PTY and
// scrollback survive the dock/undock reparent without a remount.
//
// rasterScale oversampling: when rasterScale > 1 (and not docked), the React-
// rendered raster wrapper expands the slot to rasterScale× the card size and
// applies a counter-scale CSS transform to bring it back to visual card size.
// The term-host fills the slot (so it too is rasterScale× bigger in layout).
// host.style.padding and term.options.fontSize are scaled by the same factor so
// FitAddon.fit() recomputes the SAME cols×rows — only pixel density changes.
// The xterm canvas backing is therefore rasterScale×DPR pixels per logical px.
// The existing BCR override for selection coords remains correct: because padding
// and font scale together, the BCR of .xterm and the cols×rows ratio are
// identical to the unscaled case (proven in tauri-card-crispness-fix.md math).
// When docked the effective scale is forced to 1 (dock pane has no board zoom).

import { useEffect, useLayoutEffect, useRef, useState, useContext } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { CardShell } from "./CardShell";
import { DockContext } from "./DockContext";
import { attachTermOutput, detachTermOutput, termInput, termResize } from "../ipc/daemon";
import { termFontFamily, termFontSize, xtermTheme } from "../theme";
import type { TermCardModel, WorldFrame } from "../board/model";

// host padding constants (must match .term-host in theme.css: padding: 8px 10px).
const HOST_PADDING_V_PX = 8;
const HOST_PADDING_H_PX = 10;

interface TerminalCardProps {
  model: TermCardModel;
  selected?: boolean;
  quiet?: boolean;
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
  /** Cold-spawn the PTY once the terminal has measured its cols/rows. */
  onSpawn: (cols: number, rows: number) => void;
  onTitle: (title: string) => void;
  /** A keystroke into this terminal — used to clear a lit bell (Swift parity). */
  onActivity?: () => void;
}

export function TerminalCard(props: TerminalCardProps) {
  const { model, onSpawn, onTitle } = props;

  // The host node is created ONCE (stable across dock/undock reparents). React
  // never renders it as a child — only the empty slot and dock-body are React-owned.
  const [host] = useState(() => {
    const d = document.createElement("div");
    d.className = "term-host";
    // Tag with the term id so the App can map document.activeElement → termId
    // (reconcile the ⌥Tab cycle's "current" to the visibly-focused terminal).
    d.dataset.termId = model.termId;
    return d;
  });
  const slotRef = useRef<HTMLDivElement>(null);

  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  // Read inside the (termId-scoped) onData closure so it sees the live bell state.
  const bellRef = useRef(model.bell);
  bellRef.current = model.bell;
  const onActivityRef = useRef(props.onActivity);
  onActivityRef.current = props.onActivity;
  const getZoomRef = useRef(props.getZoom);
  getZoomRef.current = props.getZoom;

  const dock = useContext(DockContext);
  const docked = dock.dockedTermId === model.termId;

  // The xterm element sits under TWO transforms when oversampling: the world's
  // scale(zoom) AND this card's counter-scale(1/rs). Its effective layout→screen
  // scale is therefore zoom/rs (and its internal cell width is c0·rs). The BCR
  // selection-coord override must divide by that combined scale, not zoom alone.
  // Pinned to 1 while docked (the host is reparented out of the board transform).
  const rsRef = useRef(1);
  rsRef.current = docked ? 1 : props.rasterScale;

  useEffect(() => {
    // Append the host into the in-card slot on initial mount.
    slotRef.current?.appendChild(host);

    let disposed = false;

    const term = new Terminal({
      fontFamily: termFontFamily,
      fontSize: termFontSize,
      theme: xtermTheme,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
      macOptionIsMeta: true,
      vtExtensions: { kittyKeyboard: true },
    });
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    const unicode = new Unicode11Addon();
    term.loadAddon(unicode);
    // unicode11 reports width=1 for PUA glyphs (U+E000–F8FF) — do NOT add a
    // blanket PUA→2 override.  This is correct because we ship the NFM (Mono)
    // variant of JetBrainsMono Nerd Font, which forces every icon glyph into a
    // single cell.  A PUA→2 override would misalign single-width powerline
    // separators (U+E0B0…).  If you ever swap to the NFP (Proportional) variant
    // you will need to revisit this.  SwiftTerm uses NFM for the same reason.
    term.unicode.activeVersion = "11";
    term.open(host);
    termRef.current = term;

    // xterm calls getBoundingClientRect() on term.element (.xterm) and
    // term.screenElement (.xterm-screen) to translate mouse coords to cells
    // (getCoordsRelativeToElement in xterm module 5251). Under the board's
    // CSS scale(zoom) transform those rects are in screen pixels while
    // cellWidth/cellHeight are layout pixels — at zoom ≠ 1 selections land
    // in the wrong cell. Fix: patch BCR on the two elements xterm actually
    // queries, converting screen-px offsets back to layout-px offsets.
    // lastMouseX/Y are updated at capture phase (before any element handler).
    //
    // Oversampling adds a SECOND transform: this card's counter-scale(1/rs). The
    // xterm element's effective layout→screen scale is the product zoom·(1/rs) =
    // zoom/rs, and its layout cell width is c0·rs — so we must divide by zoom/rs,
    // not zoom. At zoom=rs (e.g. 1.5/1.5) the combined scale is 1 and BCR is
    // untouched; at zoom=2/rs=2 it is also 1. Docked pins rs=1 → s=zoom (legacy).
    let lastMouseX = 0;
    let lastMouseY = 0;
    const trackMouse = (e: MouseEvent) => {
      lastMouseX = e.clientX;
      lastMouseY = e.clientY;
    };
    document.addEventListener("mousedown", trackMouse, { capture: true });
    document.addEventListener("mousemove", trackMouse, { capture: true });
    const fakeBCR = (orig: () => DOMRect) => (): DOMRect => {
      const r = orig();
      const s = getZoomRef.current() / rsRef.current;
      if (s === 1) return r;
      const fakeLeft = lastMouseX - (lastMouseX - r.left) / s;
      const fakeTop = lastMouseY - (lastMouseY - r.top) / s;
      return new DOMRect(fakeLeft, fakeTop, r.width / s, r.height / s);
    };
    const xtermEl = term.element!;
    const xtermScreen = term.screenElement!;
    const origElBCR = xtermEl.getBoundingClientRect.bind(xtermEl);
    const origScreenBCR = xtermScreen.getBoundingClientRect.bind(xtermScreen);
    xtermEl.getBoundingClientRect = fakeBCR(origElBCR);
    xtermScreen.getBoundingClientRect = fakeBCR(origScreenBCR);

    // Register focus handle so App can focus this terminal on dock / cycle.
    dock.registerTerm(model.termId, term);

    fit.fit();
    const cols = Math.max(2, term.cols);
    const rows = Math.max(2, term.rows);

    // Output sink must be registered before the spawn so no bytes are missed.
    void attachTermOutput(model.termId, (bytes) => term.write(bytes)).then(() => {
      if (!disposed) onSpawn(cols, rows);
    });

    const offData = term.onData((data) => {
      termInput(model.termId, data);
      // A keystroke clears this terminal's bell (only notify when one is lit, so
      // normal typing never churns React state).
      if (bellRef.current) onActivityRef.current?.();
    });
    const offResize = term.onResize(({ cols, rows }) => termResize(model.termId, cols, rows));
    const offTitle = term.onTitleChange((title) => onTitle(title));

    // Re-fit only on REAL layout size changes (card resize) — ResizeObserver does
    // not fire on CSS transforms, so zoom never triggers a re-measure. Guard the
    // 0×0 box: when this card's board is backgrounded (display:none, P5 warm-board
    // model) the observer fires with an empty contentRect, and FitAddon would
    // wrongly propose 2×1 for an already-measured terminal (cell metrics stay
    // cached > 0) — shrinking the running program's PTY. Skip until reveal (size>0).
    // The observer is placed on the host node (which travels with reparents), so
    // both dock and undock trigger a fit via the ResizeObserver.
    const ro = new ResizeObserver((entries) => {
      const r = entries[0]?.contentRect;
      if (r && (r.width > 0 || r.height > 0)) fit.fit();
    });
    ro.observe(host);

    return () => {
      disposed = true;
      dock.unregisterTerm(model.termId);
      // Drop the bridge's output channel + any pending scrollback buffer for this
      // term so a removed/pruned card doesn't leak an IpcChannel holding the
      // disposed xterm. This does NOT close the pty (the daemon already saw its
      // exit, or a board delete killed it) — it only releases the output sink.
      void detachTermOutput(model.termId);
      ro.disconnect();
      document.removeEventListener("mousedown", trackMouse, { capture: true });
      document.removeEventListener("mousemove", trackMouse, { capture: true });
      xtermEl.getBoundingClientRect = origElBCR;
      xtermScreen.getBoundingClientRect = origScreenBCR;
      offData.dispose();
      offResize.dispose();
      offTitle.dispose();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
      // Detach from whatever parent — slot or dock pane.
      host.remove();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [model.termId]);

  // Reparent the host between the in-card slot and the dock pane when the docked
  // state changes. The move changes the host's box → ResizeObserver fires → fit()
  // → termResize. Correct.
  useEffect(() => {
    const target = docked ? dock.dockSlot : slotRef.current;
    if (target && host.parentNode !== target) target.appendChild(host);
  }, [docked, dock.dockSlot, host]);

  // rasterScale oversampling: on settle, scale the host's fontSize and padding by
  // the effective scale so the xterm canvas backing is rasterScale×DPR pixels and
  // the terminal remains cols×rows-identical (see comment block at top of file).
  // Dock pane is outside board zoom — always use scale=1 there.
  //
  // MUST be useLayoutEffect: the same rasterScale commit also resizes the wrapper
  // (rs×100% width), which the host's ResizeObserver observes. Setting fontSize +
  // padding SYNCHRONOUSLY at commit — before the RO fires — means the RO's fit()
  // sees the already-scaled cell metrics and is a no-op, so the cols×rows stay
  // fixed. A passive useEffect would let the RO fit() the enlarged host against
  // the OLD base fontSize first, blowing up to ~rs× columns (a spurious PTY
  // resize + one-frame grid blow-up) before this effect corrected it back.
  useLayoutEffect(() => {
    const term = termRef.current;
    const fit = fitRef.current;
    if (!term || !fit) return;
    // When docked the host lives in the dock pane (no board zoom); reset to 1.
    const rs = docked ? 1 : props.rasterScale;
    term.options.fontSize = termFontSize * rs;
    host.style.padding = `${HOST_PADDING_V_PX * rs}px ${HOST_PADDING_H_PX * rs}px`;
    // fit() re-measures the (now rs×) host with the (now rs×) cell size and
    // arrives at the same cols×rows; the canvas is sized at rs×DPR resolution.
    fit.fit();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.rasterScale, docked]);

  const repoGlyph = "›_";
  return (
    <CardShell
      frame={model.frame}
      z={model.z}
      dead={model.dead}
      prime={model.prime}
      quiet={props.quiet}
      selected={props.selected}
      className={docked ? "docked" : undefined}
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
          <span className={`glyph${model.bell ? " bell" : ""}`}>{repoGlyph}</span>
          <span className="label">{model.label}</span>
          <span className="spacer" />
          {model.bell && <span className="bell">●</span>}
        </>
      }
    >
      {/* term-raster-clip clips the over-sized wrapper when rs > 1.
          term-raster-wrapper expands to rs× card-body size; the counter-scale
          brings it back to the original visual footprint. term-host-slot fills
          the (now larger) wrapper, so the imperative host and its xterm canvas
          are rs× bigger in layout → canvas backing is rs×DPR pixels. When
          docked the host is reparented to dock.dockSlot and the wrapper is empty;
          rasterScale is also forced to 1 in the settle effect. */}
      <div className="term-raster-clip">
        <div
          className="term-raster-wrapper"
          style={props.rasterScale !== 1 && !docked ? {
            width: `${props.rasterScale * 100}%`,
            height: `${props.rasterScale * 100}%`,
            transform: `scale(${1 / props.rasterScale})`,
            transformOrigin: "0 0",
          } : undefined}
        >
          <div className="term-host-slot" ref={slotRef} />
        </div>
      </div>
      {docked && <div className="term-dock-ghost">⏎ docked · esc ↩ to return</div>}
    </CardShell>
  );
}
