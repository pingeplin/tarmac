// Authored previews for CardShell — the shared card frame every card (doc or
// terminal) is built on (desktop/src/cards/CardShell.tsx): the 30px drag
// header, 8 always-live resize handles, and the resting/active chrome classes
// derived from the ported CardChrome rule (desktop/src/kit/cardChrome.ts).
// CardShell itself renders whatever `header`/`children` its caller supplies —
// the two real callers are DocCard and TerminalCard (see
// desktop/src/cards/{DocCard,TerminalCard}.tsx), so each story below ports
// one of those two real header shapes (glyph + repo-dot/bell + label + spacer
// + owner-chip/recency/close) verbatim, rather than inventing generic
// placeholder header content — CardShell has no header markup of its own to
// fall back on.
//
// The real variant axis CardShell actually renders differently is
// `cardChromeState` (desktop/src/kit/cardChrome.ts): dead/detached -> muted
// border, focused/selected -> the teal focus ring + handle chips, prime ->
// header tint + deeper shadow (NOT the border), fresh -> the agent-dim halo
// ring, quiet -> a flat opacity dim. The stories below sweep that whole set:
// a prime+focused terminal, a selected doc with a close button, a fresh
// (agent-just-opened) doc, a dead (process-exited) terminal, a detached doc,
// and a quiet (background) terminal.
//
// GOTCHA (see DocCard.tsx in this dir for the full writeup): CardShell's
// non-`inWrapper` mode (used by every story here, matching how DocCard/
// TerminalCard's callers actually mount it) positions itself via
// `left/top/width/height` off `frame`, which needs a real *sized*
// `position: relative` ancestor (the single-story capture wrapper alone has
// zero intrinsic height) — wrap every story in a `.board`-sized box a little
// larger than the card frame so the card doesn't clip to the wrapper edge.
import { CardShell } from "tarmac-app";

const noop = () => {};
const frame = { x: 0, y: 0, w: 360, h: 220 };

/** The steady prime state: keyboard-target terminal, focused ring + handles
 * live, header tint from `.card.prime .card-header` — the everyday look of
 * "the terminal you're typing into". Ported from TerminalCard's real header
 * (glyph + label + spacer, no bell). */
export function PrimeFocused() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={1}
        prime
        focused
        header={
          <>
            <span className="glyph">›_</span>
            <span className="label">claude</span>
            <span className="spacer" />
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontFamily: "monospace", fontSize: 12, color: "var(--text)" }}>
          $ cargo test -p tarmacd{"\n"}
          running 42 tests{"\n"}
          test result: ok. 42 passed; 0 failed
        </div>
      </CardShell>
    </div>
  );
}

/** A selected doc card with a bell-less repo dot, an owner chip, a recency
 * meta, and the close affordance — `hasClose` drops the `tr` resize handle so
 * it never collides with the ✕. Ported from DocCard's real header. */
export function SelectedWithClose() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={2}
        selected
        hasClose
        header={
          <>
            <span className="glyph">¶</span>
            <span className="repo-dot" style={{ background: "#8ab4f8" }} />
            <span className="label">README.md</span>
            <span className="spacer" />
            <span className="owner-chip">{"← agent-1"}</span>
            <span className="recency-meta">4s</span>
            <span className="close" title="Close">✕</span>
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontSize: 13, color: "var(--text)" }}>
          # Tarmac UI Kit{"\n\n"}This is a standalone preview of CardShell.
        </div>
      </CardShell>
    </div>
  );
}

/** A just-opened doc, unread — the agent-dim halo ring (`.card.fresh`) plus the
 * "✚ now" badge, distinct from the focus ring. */
export function Fresh() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={3}
        fresh
        hasClose
        header={
          <>
            <span className="glyph">¶</span>
            <span className="repo-dot" style={{ background: "#f28b82" }} />
            <span className="label">CHANGELOG.md</span>
            <span className="spacer" />
            <span style={{ color: "var(--agent)" }}>✚ now</span>
            <span className="close" title="Close">✕</span>
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontSize: 13, color: "var(--text)" }}>
          # 0.7.0{"\n\n"}WebGL terminals, daemon auto-restart, board fixes.
        </div>
      </CardShell>
    </div>
  );
}

/** A dead terminal (process exited) — `.card.dead` flattens to 55% opacity and
 * the border drops to the muted role; handles stay live so the card can still
 * be resized/closed. */
export function Dead() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={1}
        dead
        header={
          <>
            <span className="glyph">›_</span>
            <span className="label">zsh (exited)</span>
            <span className="spacer" />
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontFamily: "monospace", fontSize: 12, color: "var(--text)" }}>
          $ exit{"\n"}
          [process exited]
        </div>
      </CardShell>
    </div>
  );
}

/** A doc manually dragged away from its owning terminal — `.card.detached`
 * (50% opacity) takes precedence over the plain resting look; no owner chip
 * (the caller omits it once detached). */
export function Detached() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={1}
        detached
        hasClose
        header={
          <>
            <span className="glyph">¶</span>
            <span className="label">protocol.md</span>
            <span className="spacer" />
            <span className="close" title="Close">✕</span>
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontSize: 13, color: "var(--text)" }}>
          # Provenance edges{"\n\n"}A dashed edge ties a doc card to its owner.
        </div>
      </CardShell>
    </div>
  );
}

/** A background terminal while another is prime — `.quiet` dims to 80% opacity
 * (a lighter dim than dead/detached), no ring, header keeps the plain
 * (non-tinted) background since it isn't prime. Ported with a lit bell to
 * show the amber bell dot surviving the dim. */
export function Quiet() {
  return (
    <div className="board" style={{ position: "relative", width: 400, height: 260 }}>
      <CardShell
        frame={frame}
        z={1}
        quiet
        header={
          <>
            <span className="glyph bell">›_</span>
            <span className="label">build.sh</span>
            <span className="spacer" />
            <span className="bell">●</span>
          </>
        }
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
      >
        <div style={{ padding: 10, fontFamily: "monospace", fontSize: 12, color: "var(--text)" }}>
          Build complete. Watching for changes…
        </div>
      </CardShell>
    </div>
  );
}
