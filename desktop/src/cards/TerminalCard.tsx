// A live terminal card: hosts an xterm.js instance, streams PTY output in over a
// binary Channel, sends keystrokes/resizes out via invoke. The board's CSS zoom
// transform scales the whole card as a bitmap (matching the Swift bitmap-scale of
// SwiftTerm layers); xterm is re-measured by a ResizeObserver on the host, which
// fires both when the card is resized and when a rasterScale commit resizes the
// raster wrapper. What the grid does about each is decided in kit/termGrid.ts.
// Selection coord correction is via a getBoundingClientRect() override on host.
//
// The xterm host node is created ONCE imperatively (useState lazy init) and
// appended via appendChild — React never owns it as a child — so the PTY and
// scrollback survive re-renders without a remount.
//
// rasterScale oversampling: when rasterScale > 1, the React-rendered raster
// wrapper expands the slot to rasterScale× the card size and applies a
// counter-scale CSS transform to bring it back to visual card size.
// The term-host fills the slot (so it too is rasterScale× bigger in layout).
// term.options.fontSize is scaled by the same factor, so the grid comes out
// nearly unchanged — but not exactly: the cell size is rounded to whole device
// pixels, so it is NOT a clean multiple of the 1× one (21 → 31 → 43 → 53 → 63).
// Re-measuring on a zoom therefore moved the PTY grid under the running program,
// which is why the rasterScale path clamps against the rest grid instead of
// re-proposing freely (kit/termGrid.ts, spec 2609.0011).
// The host padding is scaled too — declaratively: the wrapper sets `--rs` and
// .term-host in theme/app-only.css multiplies its padding by it. That padding is
// real estate the grid may not use, and proposeGrid() subtracts it; the addon
// this replaced did not, which is what clipped the last row.
// The xterm canvas backing is therefore rasterScale×DPR pixels per logical px.
// The existing BCR override for selection coords remains correct: padding and
// font scale together, so .xterm's BCR scales with everything else and the
// override's zoom/rs divisor still holds (tauri-card-crispness-fix.md math).
// It does NOT depend on the grid being invariant across the step — it is not
// (kit/rasterScale.ts) — only on the geometry scaling uniformly.

import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from "react";
import { Terminal } from "@xterm/xterm";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import { WebLinksAddon } from "@xterm/addon-web-links";
import {
  INITIAL_RENDERER_STATE,
  shouldAttemptWebgl,
  onWebglLoaded,
  onContextLoss,
  onWebglUnavailable,
} from "../kit/termRenderer";
import { CardShell } from "./CardShell";
import {
  cardBox,
  nextGrid,
  proposeGrid,
  scrollbarReserve,
  type GridBox,
  type RestGrid,
} from "../kit/termGrid";
import { termInnerBox } from "../kit/termZoom";
import { attachTermOutput, detachTermOutput, termInput, termResize } from "../ipc/daemon";
import { openExternal } from "../ipc/shell";
import { termFontFamily, termFontSize, xtermTheme } from "../theme";
import type { TermCardModel, WorldFrame } from "../board/model";

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
  /** Register/unregister a focus handle so App can focus this terminal (⌥Tab cycle,
   *  board-switch/restore focus). */
  onRegister?: (termId: string, handle: { focus(): void }) => void;
  onUnregister?: (termId: string) => void;
}

/** Read the card's live box into the numbers the grid rules work on, or null
 *  while it cannot be measured (renderer not up yet, or the board is hidden
 *  behind display:none). */
function measureBox(host: HTMLDivElement, term: Terminal): GridBox | null {
  const cell = term.dimensions?.css.cell;
  if (!cell) return null;
  const pad = (style: CSSStyleDeclaration | null, side: string) =>
    style ? parseFloat(style.getPropertyValue(`padding-${side}`)) : 0;
  const h = getComputedStyle(host);
  const x = term.element ? getComputedStyle(term.element) : null;
  return {
    boxH: host.clientHeight,
    boxW: host.clientWidth,
    padV: pad(h, "top") + pad(h, "bottom") + pad(x, "top") + pad(x, "bottom"),
    padH: pad(h, "left") + pad(h, "right") + pad(x, "left") + pad(x, "right"),
    scrollbar: scrollbarReserve(term.options),
    cellW: cell.width,
    cellH: cell.height,
  };
}

export function TerminalCard(props: TerminalCardProps) {
  const { model, onSpawn, onTitle, onRegister, onUnregister } = props;

  // The host node is created ONCE (stable across re-renders). React never
  // renders it as a child — only the empty slot is React-owned.
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
  // The grid this card settled on at its current SIZE, plus the size itself. A
  // zoom clamps against it but never replaces it, so zooming back out restores
  // what zooming in gave up (kit/termGrid.ts nextGrid).
  const restRef = useRef<RestGrid | null>(null);
  const webglRef = useRef<WebglAddon | null>(null);
  // Read inside the (termId-scoped) onData closure so it sees the live bell state.
  const bellRef = useRef(model.bell);
  bellRef.current = model.bell;
  const onActivityRef = useRef(props.onActivity);
  onActivityRef.current = props.onActivity;
  const getZoomRef = useRef(props.getZoom);
  getZoomRef.current = props.getZoom;

  // The xterm element sits under TWO transforms when oversampling: the inner
  // scale(zoom) AND this card's counter-scale(1/rs). Its effective layout→screen
  // scale is therefore zoom/rs (and its internal cell width is c0·rs). The BCR
  // selection-coord override must divide by that combined scale, not zoom alone.
  const rsRef = useRef(1);
  rsRef.current = props.rasterScale;

  // Every re-measure goes through here, whatever triggered it: the card was
  // resized, or the board's zoom settled on a new rasterScale. Which one it was
  // is decided by the card box (the measurement with the rasterScale divided
  // out) — NOT by which observer fired, because a rasterScale commit resizes
  // .term-host for real (288 → 432 px at rs 1.5) and the ResizeObserver fires
  // for zooms as well as for resizes.
  const applyGrid = (term: Terminal) => {
    const box = measureBox(host, term);
    if (!box) return;
    const proposed = proposeGrid(box);
    if (!proposed) return;
    const { grid, rest } = nextGrid(proposed, restRef.current, cardBox(box, rsRef.current));
    restRef.current = rest;
    term.resize(grid.cols, grid.rows);
  };
  const applyGridRef = useRef(applyGrid);
  applyGridRef.current = applyGrid;

  useEffect(() => {
    // Append the host into the in-card slot on initial mount.
    slotRef.current?.appendChild(host);

    let disposed = false;

    // React runs layout effects before passive effects, so the rasterScale effect
    // below cannot seed a terminal that does not exist yet. Read the settled scale
    // here and apply it to fontSize before the measurement whose cols×rows onSpawn
    // ships to the PTY. (The padding needs no read: it inherits --rs from the
    // wrapper, which React already committed in the initial render.)
    const rs = rsRef.current;

    const term = new Terminal({
      fontFamily: termFontFamily,
      fontSize: termFontSize * rs,
      theme: xtermTheme,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
      macOptionIsMeta: true,
      vtExtensions: { kittyKeyboard: true },
    });
    const unicode = new Unicode11Addon();
    term.loadAddon(unicode);
    term.loadAddon(new WebLinksAddon((_event, uri) => openExternal(uri).catch(() => {})));
    // unicode11 reports width=1 for PUA glyphs (U+E000–F8FF) — do NOT add a
    // blanket PUA→2 override.  This is correct because we ship the NFM (Mono)
    // variant of JetBrainsMono Nerd Font, which forces every icon glyph into a
    // single cell.  A PUA→2 override would misalign single-width powerline
    // separators (U+E0B0…).  If you ever swap to the NFP (Proportional) variant
    // you will need to revisit this.  SwiftTerm uses NFM for the same reason.
    term.unicode.activeVersion = "11";
    term.open(host);
    termRef.current = term;

    // Attempt WebGL renderer; fall back to canvas on failure or context loss.
    let rstate = INITIAL_RENDERER_STATE;
    const probeWebgl = (): boolean => {
      try {
        const canvas = document.createElement("canvas");
        const gl = canvas.getContext("webgl2") ?? canvas.getContext("webgl");
        gl?.getExtension("WEBGL_lose_context")?.loseContext();
        return !!gl;
      } catch { return false; }
    };
    if (shouldAttemptWebgl(rstate, probeWebgl())) {
      try {
        const gl = new WebglAddon();
        gl.onContextLoss(() => {
          gl.dispose();
          rstate = onContextLoss(rstate);
          webglRef.current = null;
        });
        term.loadAddon(gl);
        rstate = onWebglLoaded(rstate);
        webglRef.current = gl;
      } catch {
        rstate = onWebglUnavailable(rstate);
      }
    }

    // Expose the xterm instance on the host DOM element so App-level keydown
    // handlers can query kitty keyboard flags (issue #21 terminal key bindings)
    // without requiring a ref-callback threading. Cleaned up in the dispose
    // closure below when termRef is also cleared.
    (host as any).__xtermTerm = term;

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
    // untouched; at zoom=2/rs=2 it is also 1.
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

    // Register focus handle so App can focus this terminal (⌥Tab cycle, restore).
    onRegister?.(model.termId, term);

    // The grid the card's content box holds, which also becomes the rest grid.
    applyGridRef.current(term);
    const cols = Math.max(2, term.cols);
    const rows = Math.max(2, term.rows);

    // Output sink must be registered before the spawn so no bytes are missed.
    void attachTermOutput(model.termId, (bytes) => term.write(bytes)).then(() => {
      if (!disposed) onSpawn(cols, rows);
    });

    // ── Input routing: unify printable keys on the `beforeinput` path ──────────
    //
    // Tier 2: a custom key-event handler suppresses xterm's OWN keydown emission for
    // plain printable single chars, so letters AND space AND punctuation all reach
    // the PTY uniformly via the `beforeinput` interceptor below — no diff race, no
    // per-key dedupe needed. attachCustomKeyEventHandler returns `false` to tell
    // xterm "do not process this key": verified in the installed source
    // (node_modules/@xterm/xterm/lib/xterm.js `_keyDown`) that the early
    //   `if(this._customKeyEventHandler&&false===this._customKeyEventHandler(e))return false`
    // returns WITHOUT preventDefault/stopPropagation, so the default action proceeds
    // and `beforeinput`/`input` still fire. We return `true` (let xterm handle it)
    // for anything that must keep xterm's key evaluation:
    //   - modifiers (ctrl/meta/alt): chords + macOptionIsMeta (⌥O must emit ESC o,
    //     not ø) need xterm's keydown path.
    //   - kitty keyboard active: don't break progressive-enhancement sequences for
    //     plain keys (kittyActive reads the same per-terminal runtime flag App.tsx
    //     uses: term._core._coreService.kittyKeyboard.flags).
    //   - composition (isComposing) or multi-char keys (Enter/Esc/Tab/arrows/F-keys,
    //     e.key.length !== 1): owned by xterm / its CompositionHelper.
    const kittyActive = (): boolean =>
      !!((term as any)?._core?._coreService?.kittyKeyboard?.flags);
    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== "keydown") return true;
      if (e.isComposing) return true;
      if (e.ctrlKey || e.metaKey || e.altKey) return true;
      if (kittyActive()) return true;
      if (e.key.length !== 1) return true;
      return false; // plain printable single char → handled by `beforeinput`.
    });

    // Echo dedupe state — set by onData, read by the beforeinput interceptor. With the
    // Tier 2 custom handler above, onData and beforeinput are now MUTUALLY EXCLUSIVE
    // per key: plain printables go only through beforeinput, and any key xterm does
    // emit from keydown (e.g. ⌥-as-meta) is followed by xterm's own preventDefault()
    // (verified in `_keyDown`: after triggerDataEvent it always calls
    // preventDefault/stopPropagation since screenReaderMode is off), which suppresses
    // beforeinput. So this dedupe is now defensive insurance, not load-bearing. The
    // flag is reset at the START of every keydown (capture phase, before xterm's
    // handler) so its lifetime is exactly one physical key: keydown(reset) →
    // onData(set) → beforeinput(read). It must NOT be cleared by a microtask — the
    // browser drains microtasks when the keydown dispatch's JS stack empties, BEFORE
    // the default action dispatches beforeinput, which would clear it too early. The
    // keydown reset also clears a stale flag left by keys that emit onData but no
    // beforeinput (Enter, arrows).
    let echoData = "";
    let xtermSent = false;
    const ta = term.textarea;
    const offIme: Array<() => void> = [];
    if (ta) {
      const onKeyDownReset = () => { xtermSent = false; };
      ta.addEventListener("keydown", onKeyDownReset, true);
      offIme.push(() => ta.removeEventListener("keydown", onKeyDownReset, true));
      // macOS CJK IMEs in alphanumeric mode deliver every ASCII key as a committed
      // `insertText` whose char is authoritative in `e.data`. We intercept the
      // committed text directly and preventDefault so the textarea never mutates
      // (xterm's diff path is a no-op and cannot echo). Real compositions
      // (isComposing) and non-insert edits are left to xterm.
      const onBeforeInput = (e: InputEvent) => {
        if (e.isComposing || e.inputType !== "insertText" || e.data == null) return;
        e.preventDefault();
        if (xtermSent && e.data === echoData) return;
        termInput(model.termId, e.data);
        if (bellRef.current) onActivityRef.current?.();
      };
      ta.addEventListener("beforeinput", onBeforeInput, true);
      offIme.push(() => ta.removeEventListener("beforeinput", onBeforeInput, true));
    }

    const offData = term.onData((data) => {
      xtermSent = true;
      echoData = data;
      termInput(model.termId, data);
      // A keystroke clears this terminal's bell (only notify when one is lit, so
      // normal typing never churns React state).
      if (bellRef.current) onActivityRef.current?.();
    });
    const offResize = term.onResize(({ cols, rows }) => termResize(model.termId, cols, rows));
    const offTitle = term.onTitleChange((title) => onTitle(title));

    // Fires for BOTH card resizes and rasterScale commits (the latter really do
    // resize the host — the wrapper goes rs×100% and the host is inset:0 of it).
    // applyGrid tells them apart; this callback only has to skip the 0×0
    // contentRect a backgrounded board reports (display:none, P5 warm-board
    // model), which proposeGrid would reject anyway — shrinking a live program's
    // PTY to 2×1 is the failure being guarded against, twice.
    const ro = new ResizeObserver((entries) => {
      const r = entries[0]?.contentRect;
      if (!r || (r.width === 0 && r.height === 0)) return;
      applyGridRef.current(term);
    });
    ro.observe(host);

    return () => {
      disposed = true;
      onUnregister?.(model.termId);
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
      offIme.forEach((off) => off());
      offData.dispose();
      offResize.dispose();
      offTitle.dispose();
      webglRef.current?.dispose();
      webglRef.current = null;
      term.dispose();
      termRef.current = null;
      restRef.current = null;
      delete (host as any).__xtermTerm;
      host.remove();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [model.termId]);

  // rasterScale oversampling: on settle, scale the host's fontSize by the effective
  // scale so the xterm canvas backing is rasterScale×DPR pixels. The padding
  // scales in the same commit via --rs (see comment block at top of file).
  //
  // The grid ends up CLAMPED rather than re-proposed, because applyGrid sees the
  // same card box at a new rasterScale (kit/termGrid.ts nextGrid).
  //
  // MUST be useLayoutEffect: the same rasterScale commit also resizes the wrapper
  // (rs×100% width), which the host's ResizeObserver observes. Setting fontSize
  // SYNCHRONOUSLY at commit — before the RO fires — means the RO measures the new
  // box against the new cell. A passive useEffect would let it measure the new box
  // against the OLD cell first: on the way DOWN that under-proposes, and since the
  // clamp takes minimums it would apply the shrink and keep it until the next card
  // resize. (On the way up the mismatch over-proposes, which the clamp absorbs.)
  // The RO firing after this effect is harmless: same box, same card, same
  // decision, and term.resize on an unchanged grid is a no-op.
  useLayoutEffect(() => {
    const term = termRef.current;
    if (!term) return;
    term.options.fontSize = termFontSize * props.rasterScale;
    applyGridRef.current(term);
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.rasterScale]);

  const repoGlyph = "›_";
  return (
    <CardShell
      frame={model.frame}
      dead={model.dead}
      prime={model.prime}
      quiet={props.quiet}
      selected={props.selected}
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
      {/* The zoom-free host box. It wraps the body ONLY — the header is outside
          it, in real-px chrome, so titles are laid out per zoom rather than
          upscaled with the host. Everything below is unchanged by that move.

          term-raster-clip clips the over-sized wrapper when rs > 1.
          term-raster-wrapper expands to rs× card-body size; the counter-scale
          brings it back to the original visual footprint. term-host-slot fills
          the (now larger) wrapper, so the imperative host and its xterm canvas
          are rs× bigger in layout → canvas backing is rs×DPR pixels. */}
      <div style={termInnerBox()}>
        <div className="term-raster-clip">
          <div
            className="term-raster-wrapper"
            style={{
              "--rs": String(props.rasterScale),
              ...(props.rasterScale !== 1 ? {
                width: `${props.rasterScale * 100}%`,
                height: `${props.rasterScale * 100}%`,
                transform: `scale(${1 / props.rasterScale})`,
                transformOrigin: "0 0",
              } : {}),
            } as CSSProperties}
          >
            <div className="term-host-slot" ref={slotRef} />
          </div>
        </div>
      </div>
    </CardShell>
  );
}
