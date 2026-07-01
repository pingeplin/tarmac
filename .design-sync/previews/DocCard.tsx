// Authored previews for DocCard — the markdown doc card (desktop/src/cards/DocCard.tsx).
// Ported from the hand-authored fixture at desktop/scripts/kit-fixtures.mjs (used by
// the build-kit.mjs preview pipeline for issue #47) and extended to sweep the
// fresh/attached/selected state axis DocCard actually renders differently for.
//
// DocCard always renders with CardShell's `inWrapper` mode (fills its parent via
// `inset: 0`, no left/top/width/height of its own) and its .doc-prose layout reads
// `var(--card-w)` — both need a sized, positioned-enough ancestor. The real app
// wraps every doc card in `.board` (see desktop/src/board/Board.tsx); wrapping each
// story the same way here matches production DOM shape 1:1, per the fixture's
// `wrapInBoard: true` flag for this component.
//
// IMPORTANT (gotcha for the next wave): `.board` carries ZERO CSS in the kit
// bundle — app-only.css (which defines `.board { position: relative; ... }`) is
// deliberately excluded from kit.css (see desktop/src/theme/kit.css's header
// comment), so the class alone is cosmetic parity, not a working containing
// block. The design-sync single-story capture wraps each story in a bare
// `.ds-single` div (`transform: translateZ(0)`, no explicit size) — that DOES
// make it a containing block for position:absolute/fixed descendants, but it
// has ZERO intrinsic height because DocCard's whole subtree is
// position:absolute (CardShell's `inWrapper` mode). `inset: 0` against a
// 0-height containing block resolves to a 0-height card — the story clips to a
// 1px sliver (just the top border). The fix is an explicit inline size on the
// `.board` wrapper itself (`position: relative` + matching the frame's w/h) so
// there's a real, non-zero containing block for CardShell to fill.
import { DocCard } from "tarmac-app";

const noop = () => {};

// A generous excerpt of real project prose (extended from the kit-fixtures.mjs
// DocCard markdown) — headings, a bullet list, and a blockquote.
const readmeMarkdown =
  "# Tarmac UI Kit\n\n" +
  "This is a **standalone** preview of `DocCard`, rendered with no daemon and no " +
  "live `BoardEngine` behind it.\n\n" +
  "## What's real here\n\n" +
  "- prose collapses without `--card-w`/`--card-h` on `:root`\n" +
  "- fixed here by `preview-defaults.css` (kit-only, never shipped to the app)\n" +
  "- markdown is parsed by the `marked` library, inlined into the bundle\n" +
  "- every mark on the real board is backed by an observable OS fact\n\n" +
  "> Every mark on the board is backed by an observable OS fact — never by " +
  "parsing agent output.\n";

// A shorter, differently-shaped excerpt (ordered list + inline code) so the
// Fresh cell doesn't just look like a shrunk copy of Selected.
const changelogMarkdown =
  "# 0.7.0\n\n" +
  "WebGL terminals, daemon auto-restart, board fixes.\n\n" +
  "1. Terminal surfaces now render via WebGL when available\n" +
  "2. `tarmacd` auto-restarts the app on a version mismatch\n" +
  "3. Board card gravity bugs fixed\n\n" +
  "Run `tarmac open docs/CHANGELOG.md` to see this card live.\n";

// A spec-style excerpt with a blockquote and inline code, for the detached story.
const specMarkdown =
  "# Provenance edges\n\n" +
  "A dashed edge ties a doc card to the terminal that opened it via `tarmac open`.\n\n" +
  "> Detaching a card (manual drag) severs the edge — the daemon persists " +
  "`loose = true` and stops re-parenting the card to its owner.\n\n" +
  "- `attached: false` on the model\n" +
  "- no owner chip in the header\n";

/** Selected + attached, with a live owner chip and a recent-change badge — the
 * common steady-state look for a doc a terminal just opened. */
export function Selected() {
  return (
    <div className="board" style={{ position: "relative", width: 360, height: 520 }}>
      <DocCard
        model={{
          kind: "doc",
          path: "/Users/dev/tarmac/docs/README.md",
          frame: { x: 0, y: 0, w: 360, h: 520 },
          z: 1,
          ownerTermId: "term-1",
          repoColor: 2,
          fresh: false,
          attached: true,
        }}
        markdown={readmeMarkdown}
        ownerName="agent-1"
        lastChangedMs={Date.now() - 4000}
        selected
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
        onClose={noop}
      />
    </div>
  );
}

/** A just-opened doc (`fresh: true`) — the "✚ now" badge plus the owner chip and
 * a fresh (<1s) recency meta. Unselected, so the selection ring drops out too. */
export function Fresh() {
  return (
    <div className="board" style={{ position: "relative", width: 360, height: 520 }}>
      <DocCard
        model={{
          kind: "doc",
          path: "/Users/dev/tarmac/CHANGELOG.md",
          frame: { x: 0, y: 0, w: 360, h: 520 },
          z: 2,
          ownerTermId: "term-2",
          repoColor: 0,
          fresh: true,
          attached: true,
        }}
        markdown={changelogMarkdown}
        ownerName="claude"
        lastChangedMs={Date.now() - 200}
        selected={false}
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
        onClose={noop}
      />
    </div>
  );
}

/** A manually-dragged-away doc (`detached: true`, `attached: false` on the model) —
 * no owner chip (ownerName omitted), no recency meta, dimmed via CardShell's
 * `.card.detached` rule. */
export function Detached() {
  return (
    <div className="board" style={{ position: "relative", width: 360, height: 520 }}>
      <DocCard
        model={{
          kind: "doc",
          path: "/Users/dev/tarmac/docs/protocol.md",
          frame: { x: 0, y: 0, w: 360, h: 520 },
          z: 1,
          repoColor: 3,
          fresh: false,
          attached: false,
        }}
        markdown={specMarkdown}
        selected={false}
        detached
        getZoom={() => 1}
        onMove={noop}
        onGrab={noop}
        onClose={noop}
      />
    </div>
  );
}
