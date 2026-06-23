// A live terminal card: hosts an xterm.js instance, streams PTY output in over a
// binary Channel, sends keystrokes/resizes out via invoke. The board's CSS zoom
// transform scales the whole card as a bitmap (matching the Swift bitmap-scale of
// SwiftTerm layers); xterm is only ever re-measured by `fit()` on a real layout
// resize — driven by a ResizeObserver, which does NOT fire on CSS transforms — so
// the xterm-under-transform measurement bug never triggers.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { CardShell } from "./CardShell";
import { attachTermOutput, termInput, termResize } from "../ipc/daemon";
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
  const hostRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  // Read inside the (termId-scoped) onData closure so it sees the live bell state.
  const bellRef = useRef(model.bell);
  bellRef.current = model.bell;
  const onActivityRef = useRef(props.onActivity);
  onActivityRef.current = props.onActivity;

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    let disposed = false;

    const term = new Terminal({
      fontFamily: termFontFamily,
      fontSize: termFontSize,
      theme: xtermTheme,
      cursorBlink: true,
      scrollback: 5000,
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    const unicode = new Unicode11Addon();
    term.loadAddon(unicode);
    term.unicode.activeVersion = "11";
    term.open(host);
    termRef.current = term;

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
    // not fire on CSS transforms, so zoom never triggers a re-measure.
    const ro = new ResizeObserver(() => fit.fit());
    ro.observe(host);

    return () => {
      disposed = true;
      ro.disconnect();
      offData.dispose();
      offResize.dispose();
      offTitle.dispose();
      term.dispose();
      termRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [model.termId]);

  const repoGlyph = "›_";
  return (
    <CardShell
      frame={model.frame}
      z={model.z}
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
      <div className="term-host" ref={hostRef} />
    </CardShell>
  );
}
