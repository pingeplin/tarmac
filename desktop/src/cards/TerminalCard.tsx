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

import { useEffect, useRef, useState, useContext } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { CardShell } from "./CardShell";
import { DockContext } from "./DockContext";
import { attachTermOutput, detachTermOutput, termInput, termResize } from "../ipc/daemon";
import { termFontFamily, termFontSize, xtermTheme } from "../theme";
import type { TermCardModel, WorldFrame } from "../board/model";

interface TerminalCardProps {
  model: TermCardModel;
  selected?: boolean;
  quiet?: boolean;
  getZoom: () => number;
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
  // Read inside the (termId-scoped) onData closure so it sees the live bell state.
  const bellRef = useRef(model.bell);
  bellRef.current = model.bell;
  const onActivityRef = useRef(props.onActivity);
  onActivityRef.current = props.onActivity;
  const getZoomRef = useRef(props.getZoom);
  getZoomRef.current = props.getZoom;

  const dock = useContext(DockContext);
  const docked = dock.dockedTermId === model.termId;

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
      const zoom = getZoomRef.current();
      if (zoom === 1) return r;
      const fakeLeft = lastMouseX - (lastMouseX - r.left) / zoom;
      const fakeTop = lastMouseY - (lastMouseY - r.top) / zoom;
      return new DOMRect(fakeLeft, fakeTop, r.width / zoom, r.height / zoom);
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
      {/* The slot stays empty — the host node is appended imperatively to avoid
          React-vs-manual child conflicts. The ghost is a sibling of the slot. */}
      <div className="term-host-slot" ref={slotRef} />
      {docked && <div className="term-dock-ghost">⏎ docked · esc ↩ to return</div>}
    </CardShell>
  );
}
