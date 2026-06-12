# Tarmac M1 — crib: desk, pinned tiles, drag-swap

Exact values + behaviors for the Swift/AppKit implementer. Sources: README §5 "Desk + pinned
tiles" + "State Management"; `tarmac-proto/desk.jsx` (primary behavioral spec), `app.jsx`
(pin/unpin/swap state), `proto.css`; `tarmac/theme.css` (tokens, `.tm-tile`), `converged.css`.
Color hex values are the **verified** oklch→sRGB conversions from `docs/m0/visual-crib.md` —
reuse them, never recompute. Where README and prototype disagree, README wins (conflicts are
called out). Lines starting with `DECISION:` are choices made where both sources are silent.

Scope: M1 only. **Edge-split drop on drag is OUT of scope** — designed (README §5: "edge-split
drop is designed — dashed cyan zone preview — but optional"; "Accepted tradeoffs": "Drag = swap
only in prototype; edge-split designed but unbuilt"). M1 implements **swap only**. Also out:
terminal tabs, foreground-process labels, bell dots, elapsed-run timers in the terminal header
(all M2); strips (M3).

## 1. Desk grid

Container (`proto.css .tm-desk`; identical in `theme.css .tm-deskbg`; README §5):

- fills the main row (`flex: 1`), `min-width/min-height: 0`
- **padding 12px**, **gap 10px**, background bg0 `#0c0e12`, `position: relative`
  (it is the positioning context for toasts/peek)

### Tile-count templates

**The terminal counts as a tile.** The desk order is one array `["term", ...pinnedDocIds]`
(`app.jsx initialStripState` → `order: ["term"]`; `desk.jsx` comment "order = [\"term\",
...docIds]"). `n` below = `order.length`. Source: `desk.jsx deskGridStyle(n)` /
`slotStyle(n, i)`; README §5 "Grid by tile count" agrees exactly.

| n | grid-template-columns | grid-template-rows | placement (row-major, by `order` index) |
|---|---|---|---|
| 1 | `1fr` | `1fr` | [0] full desk (launch state: terminal alone) |
| 2 | `1.35fr 1fr` | `1fr` | [0] left, [1] right |
| 3 | `1.35fr 1fr` | `1fr 1fr` | **[0] spans both rows** (`grid-row: 1 / 3`), [1] top-right, [2] bottom-right |
| 4 | `1.25fr 1fr` | `1.3fr 1fr` | [0] top-left, [1] top-right, [2] bottom-left, [3] bottom-right |

- The n=3 row-span belongs to **slot index 0**, not to any particular tile
  (`slotStyle(n, i)` keys off `i === 0`). After a swap, whatever tile sits at index 0
  spans — usually the terminal, but only until the user swaps it away.
- Template changes on pin/unpin are **instant re-layout** — no FLIP/reflow animation in the
  prototype. Do not animate tile resizing.

### Cap / desk-full

The prototype has **no cap**: `app.jsx pinPeek` appends unconditionally, and at n=5
`deskGridStyle` still returns the 4-template, so the 5th tile falls into an implicit auto
third row — a visibly degenerate state the design never templates. README templates stop
at 4 and say nothing about more.

DECISION: cap the desk at **4 tiles total** (terminal + 3 pinned docs). A 4th doc cannot be
pinned alongside the terminal.

DECISION: `⌘⏎` pin while the desk is full is rejected: the peek **stays open** (nothing is
silently lost) and a toast appears — `desk full` / body `✕ on a tile unpins it` — using the
M0 toast spec (bg2, 9px radius, 7s, 180ms entry).

## 2. Tile anatomy

Tile container (`theme.css .tm-tile`):

- background bg1 `#12151a`; border **1px solid** line `#262c36`; **radius 9px**
- `overflow: hidden`; flex column; `min-width/min-height: 0`; `position: relative`
- base transition (desk only, `proto.css .tm-desk .tm-tile`):
  `box-shadow 0.15s ease, border-color 0.15s ease` — this is what fades the drag
  lift/target styling in and out; tiles have no idle hover state of their own.

### 28px header (`theme.css .tm-tile .thd`)

- height **28px**, padding **0 10px**, flex row, `align-items: center`, **gap 7px**
- background bg2 `#191d24`; border-bottom 1px solid line-soft `#1d222b`
- font mono **400 10.5px**, color muted `#8c93a0`
- `cursor: pointer` and `user-select: none` (`proto.css` lines 8–9, 28) — the header is the
  drag handle (§4).

Contents left→right (doc tile, `desk.jsx DocTile`):

1. **kind glyph** `¶` — color faint `#5a616d` (`theme.css .thd .kind`). Terminal tile uses
   `›_` (`desk.jsx TermTile`).
2. **repo dot** — `RepoDot` (`tarmac/parts.jsx` → `theme.css .tm-repodot`): **7×7px** circle,
   background `var(--tm-repo-{a..d})` (verified hexes in the M0 crib: `#d78e88` `#81b482`
   `#89a4de` `#be92c8`; stable hash of repo name). The terminal tile header has **no repo
   dot** in the prototype.
3. **path** — `{repo}/{name}`, e.g. `payments-api/docs/handoff.md`; inherits header font
   (mono 400 10.5px muted). Truncation: the prototype defines none (the tile's
   `overflow: hidden` just clips).
   DECISION: render as a single non-wrapping line, **middle-truncated** with `…`
   (`NSLineBreakMode.byTruncatingMiddle` — macOS path convention; keeps repo prefix and
   filename visible).
4. **honest meta**, right-aligned (see §3).
5. **unpin ✕**, rightmost (doc tiles only — the terminal tile has no ✕ and cannot be
   unpinned; `TermTile` renders none).

**CONFLICT (README wins) — meta alignment.** README §5: "honest meta right-aligned, ✕ unpin".
The prototype's `DocTile` places the meta immediately after the path (only the ✕ carries
`margin-left: auto`), while its `TermTile` right-aligns the meta. Spec: **right-align the
meta** on all tiles — layout the right edge as `[meta][gap 7px][✕]`, path takes the
remaining space.

### Unpin ✕ (`desk.jsx DocTile`, `proto.css .tm-tile .thd .x`)

- label text is literally **`⌘⏎ ✕`** (it advertises the keyboard route); tooltip
  `unpin (back to dock)`
- geometry: font-size **10px** (mono inherited), padding **2px 5px**, border-radius **4px**,
  color faint `#5a616d`
- hover: background bg3 `#20252e`, color text `#d8dbe2`
- click: unpins the doc (event does not propagate to the header); pointer-down on the ✕
  **never starts a drag** (`desk.jsx startDrag`: `if (e.target.closest(".x")) return`).

### Tile body

- Doc tile: `.tm-docwrap` — background bg1, `overflow: hidden`; content is the same doc
  viewer as the peek (M1: the WKWebView `DocTemplate.html` from M0, including `.tm-changed`
  highlighting, live-reload, scroll preservation). One webview per pinned tile.
- Terminal tile: the SwiftTerm surface, term-bg `#0a0c10`, per the M0 crib. **No tab strip
  in M1** (`tm-ttabs` is M2+); the body sits directly under the 28px header.

### Terminal tile header in M1

The prototype's terminal header shows `claude · payments-api`, a blinking `⠧`, a bell dot
and a right-aligned run timer (`desk.jsx TermTile`) — **all of that is M2** (foreground
process, bell, elapsed). M1 has no process-name correlation.

DECISION: M1 terminal tile header = `›_` glyph + the basename of the command the daemon
spawned (e.g. `zsh`) — an observable fact known at spawn time, no process-table polling.
No repo dot, no spinner, no bell dot; right-aligned meta area empty.

## 3. Honest meta — exact M1 format

Doc tile meta (`desk.jsx DocTile`):

- shown **only while** `now − lastChangedAt < 30000` ms (the same 30s "recent" window the
  dock pulse uses); after 30s it disappears entirely — nothing replaces it.
- text: `✎ Ns` where `N = max(1, round((now − lastChangedAt) / 1000))` — so it starts at
  `✎ 1s` and counts up to `✎ 30s`.
- style: font mono **400 9.5px**, color agent `#4eccd3` (full opacity — unlike the peek
  header's 85%).
- **It ticks live**: the prototype re-renders on a 400ms clock (`app.jsx` `setInterval(...,
  400)`), so the seconds count visibly updates. Native: a 1Hz timer while any tile meta is
  visible is sufficient (display granularity is 1s).

**M1 degradation of "during <process>":** the designed full format is
`✎ 5s · during claude` (peek header, `panels.jsx PPeek`; README core model §2). Process
correlation does not exist until M2, so **in M1 every such meta renders the time part only:
`✎ 5s`** — on tiles (where the prototype already omits "during"), in the peek header, and
anywhere else the format appears. Never show a process name in M1.

## 4. Pin / unpin choreography

State source: `app.jsx pinPeek / unpin / swapTiles`; dock highlight: `panels.jsx PDock`.

### `⌘⏎` with a peek open (pin)

1. If the peeked doc is **not** pinned: append its id to the **end of `order`** (it takes
   the last slot of the new template — e.g. pinning the 2nd doc puts it bottom-right and
   promotes slot 0 to the row-spanning tile), and clear the peek.
2. The peek **closes by sliding out** — the `transform` transition on `.tm-peek` runs both
   directions, so dismissal is the same **220ms `cubic-bezier(0.2, 0.8, 0.2, 1)`**
   (`proto.css .tm-peek`; M0 crib "peek slide").
3. The tile appears instantly with the grid re-template — no entrance animation.
4. `⌘⏎` with no peek open is a no-op (`pinPeek` guard).

**CONFLICT (README wins) — `⌘⏎` on an already-pinned doc.** README "Interactions":
"`⌘⏎` pin/**unpin** peeked doc" (a toggle). The prototype only closes the peek in that case
(`pinPeek`: `order.includes(ss.peek)` → `closePeek()`), leaving the tile pinned. Spec:
**toggle** — peeking an already-pinned doc and pressing `⌘⏎` **unpins it** (tile removed)
and closes the peek. (The tile's `⌘⏎ ✕` label only makes sense under toggle semantics.)

### Unpin (✕ click, or `⌘⏎` toggle above)

- `order` drops the doc id; remaining tiles close up in their existing relative order and
  the grid re-templates to n−1 (instant, no animation).
- **The dock never changed.** Pinning does not remove a doc from the dock list and unpinning
  does not re-insert it — `app.jsx pinPeek/unpin` touch only `order`, never `dock`. "Returns
  to dock" is purely visual: the dock icon loses its active highlight.
- While pinned, the doc's dock icon shows the **active state**: bg2 + 1px line border + text
  color (`panels.jsx PDock`: class `on` when `pinned.includes(id)`; `converged.css
  .tm-dock .doc.on`). So yes — **a pinned doc still appears in the dock strip**, highlighted.
- Unpinning does not affect an open peek (independent state).

## 5. Drag-swap

Source: `desk.jsx` `startDrag`/`move`/`up` + `proto.css .tm-tile.dragging/.droptarget`.
README §5 "Drag" paragraph agrees on every shared value.

### Initiation

- Drag region: the **28px header only** (`dragProps` = `onPointerDown` on `.thd`). Pointer-down
  on the unpin `✕` (or, M2+, a terminal tab) is excluded and never drags.
- **No movement threshold**: the prototype enters drag state on pointer-down (`dx: 0, dy: 0`).
  A press-and-release without movement is harmless (no target → no-op). Match this; the
  header has no competing click action.
- The **terminal tile drags identically** — same handler on its header (README: "Terminal
  tile drags too").

### Lift styling (`proto.css .tm-tile.dragging` + inline transform)

- shadow `0 18px 44px rgba(0, 0, 0, 0.6)`
- border-color `#39414e` (authored hex; replaces line `#262c36`)
- transform: `translate(dx, dy) rotate(-0.5deg)` where `dx/dy` = pointer delta since
  pointer-down — the tile **follows the pointer 1:1, preserving the grab offset**, with no
  smoothing or lag. Opacity is unchanged (1.0).
- `z-index: 6` — above the peek (z 4), below toasts (z 7).
- `transition: none` while dragging — the lift shadow/border **pop on instantly**; on release
  the class drops and the base `0.15s ease` transition fades them back out.
- `pointer-events: none` on the dragged tile (web mechanism so hover passes through). Native
  equivalent: hit-test other tiles' frames by pointer location, skipping the dragged tile.
- The tile **stays in its grid slot** during the drag (layout does not reflow); it is only
  visually translated above its siblings. Content keeps rendering live.

Note: `theme.css .tm-tile.lift` (rotate −0.6°, translateY −4px) is a **static-mock variant**
— non-normative. README §5 and the prototype agree on **−0.5°** + pointer-follow; use that.
Likewise `theme.css .tm-dropslot` (1.5px dashed `--tm-line`) is the unbuilt edge-split
preview — out of scope.

### Hovered target (`proto.css .tm-tile.droptarget`)

- Hit test: the (single) non-dragged tile whose **full bounding rect** contains the pointer
  — the whole tile, not just its header (`desk.jsx move`). The dragged tile's own slot is
  never a target. The test is pure geometry: a tile visually under the open peek can still
  be a target (prototype behavior; acceptable in M1).
- Styling: border **1.5px dashed** agent `#4eccd3` (replaces the 1px solid border — width
  changes to 1.5px). Border-color change fades via the base `0.15s ease` transition.
- No live reorder preview — tiles do not shuffle while hovering; the dashed border is the
  only feedback.

### Release

- Pointer-up over a target → **swap**: the two ids exchange positions in `order`
  (`app.jsx swapTiles` — a strict **slot exchange**, never an insert/reorder; all other
  tiles keep their slots). Because the n=3 row-span belongs to slot 0, swapping into slot 0
  hands over the spanning cell.
- The inline transform clears with the drag state: the tile **snaps instantly** to its
  (possibly new) slot — transform is not in the transition list. Shadow + border fade out
  over 0.15s ease. No settle animation.
- Pointer-up over no tile (gaps, dock, rail, outside the window) → **cancel**: no swap,
  instant snap-back, same fade-out.

DECISION: native additions where the prototype is silent — `esc` during a drag cancels it
(snap back, no swap; do not let it fall through to peek/toast dismissal), and the drag uses
pointer capture so leaving the window bounds keeps tracking; releasing outside any tile
cancels as above. Snap-back stays instant (matches the prototype's behavior).

### Drag/easing summary

| Motion | Spec | Source |
|---|---|---|
| lift on (shadow, border, rotate) | instant (`transition: none`) | proto.css `.tm-tile.dragging` |
| follow pointer | 1:1 translate, no easing | desk.jsx `move` |
| droptarget border in/out | 150ms ease (border-color) | proto.css `.tm-desk .tm-tile` |
| release settle (shadow/border off) | 150ms ease; position snap instant | same |
| peek slide-out on pin | 220ms `cubic-bezier(0.2, 0.8, 0.2, 1)` | proto.css `.tm-peek` |
| grid re-template (pin/unpin/swap) | none — instant | desk.jsx (no animation) |

Reduce Motion: the prototype gates peek/toast/pulse/blink but **not** the 150ms shadow/border
fades (`proto.css` `@media` blocks; `.tm-app.still` covers `.tm-blink/.tm-cursor/.upd` only)
— keep the fades under Reduce Motion; the 220ms peek slide is gated per the M0 crib.

## 6. Layout persistence

Per README "State Management" + §5 "Layout persists per strip", "the layout" is exactly:

- **`order`** — the pinned tile order **including the terminal's position** (the `"term"`
  sentinel is an ordinary element of the array; its index is part of the layout)
- **`dock`** — the ordered dock doc list (independent of `order`; never mutated by
  pin/unpin/swap)

plus per-doc registry data the daemon already owns (path, repo, repo color index,
`openedVia`, read flag, `lastChangedAt`). Active terminal tab and peeked doc are also listed
as per-strip state, but tabs are M2+ and the restore experience is M3.

Ownership (README "Implementation decisions" boundary table): durable session state — dock
list, layout — is **daemon** source-of-truth; drag-in-progress and other live view state is
**app**-owned and never persisted.

DECISION: M1 extent (full "per-strip layout persistence" + restore card are M3): the app
reports the layout to the daemon on every change — each pin, unpin, and completed swap, and
each dock mutation (one `layout_changed`-style message carrying `{order, dock}`; the M0
protocol has no such frame yet, so M1 adds it per the README's `LayoutChanged` sketch). The
daemon holds it in its single implicit strip's state so an app reconnect within the daemon's
lifetime restores the desk; surviving a daemon restart and the restore-card UX stay in M3.
The peeked doc is **not** persisted or restored in M1.
