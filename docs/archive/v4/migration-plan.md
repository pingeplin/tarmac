# v4 Whiteboard — visual migration plan

Target: `design_handoff_tarmac/Tarmac Cockpit - v4 Whiteboard.html` and its
sources (`tarmac/board-v4*.jsx`, `tarmac/canvas-v4.jsx`, `tarmac/board.css`,
`tarmac/breeze.css`, layered over `theme.css` + `converged.css`).

The current app implements the **v3 model** (M1: desk grid + dock/index +
peek/pin). v4 replaces the layout model — *strip = infinite whiteboard,
terminal and docs = free cards* — and rethemes the whole UI to Ghostty
**Breeze**. The honest-signal model (process table · fswatch · CLI · bell) is
unchanged, so the daemon protocol changes are additive only.

## 1 · Design ↔ implementation comparison

| Aspect | v4 design | Current (M1) | Verdict |
| --- | --- | --- | --- |
| Theme | Breeze full-UI: bg0 `#24282c`, card `#2b3036`, header `#353b41`, term `#31363b`, line `#474e55`, text `#eff0f1`, agent cyan `#1abc9c`, amber `#fdbc4b`, ok `#1cdc9a`, repo `#f67400/#11d116/#1d99f3/#9b59b6` | Pre-Breeze dark: bg0 `#0c0e12`, term `#0a0c10`, agent `#4eccd3`, amber `#e1ad63`, dusty repo palette (`Theme.swift`) | **Replace tokens wholesale** |
| Layout model | Infinite canvas; cards carry world-space x/y/w/h; pan + zoom; position *is* memory, saved per strip | `DeskLayout` fraction templates, ≤4 slots, slot order only | **Rebuild** (`DeskGridView` → `BoardView`) |
| Terminal placement | A card like any other, but kept primary via focus model / gravity / cockpit dock | Peer tile, always present, slot 0 default | Rebuild on card model + new primacy mechanics |
| Card chrome | 30px header, radius 10, shadow `0 16px 38px 50%`, variants `sel` (cyan border + 7px corner handles), `fresh` (cyan ring), `dim`, `prime`, `quiet`, `edit` | 28px header, radius 9, lift/drop-target styling only | Extend `TileView` → `CardView`; most header internals (kind glyph, repo dot, `✎ Ns` meta) carry over |
| Drag | Free move; drag terminal moves its doc satellites (gravity); resize via corner handles | Header drag = strict slot swap, −0.5° lift | Replace swap with move; keep lift styling; add resize |
| Doc arrival | `tarmac open` lands a fresh card **next to the calling terminal card** + provenance edge; esc → shelf | Toast + dock icon pulse; pin via peek ⌘⏎ | Rework `docOpened` handling; pin/unpin + 4-tile cap removed |
| Dock / index (46px / 224px rails) | **Gone** — replaced by the shelf (top-left chip strip for open-but-unplaced docs) | `DockView`, `IndexView`, dock-birth slide | Remove rails; add `ShelfView` |
| Peek | Kept: ⌘click/⌘P floats a layer, ⌘⏎ lands it as a card | `PeekPanel` slide-over 47%, ⌘⏎ = pin to grid | Keep panel; retarget ⌘⏎ to "land card at gravity position" |
| Provenance edges | Dashed cyan bézier from caller terminal card to doc card, optional `tarmac open · HH:MM` label | None | New edge layer under cards |
| Wayfinding | Zoom control (− % + fit, bottom-left), minimap (132×88 bottom-right, signal-colored rects + viewport), offscreen signal pills at edges (⏎ fly / esc fly back) | None (everything always visible) | New board chrome views |
| Semantic zoom | Below readability threshold cards render as `tm-locard`: name + signal only, denser dot grid | None | New low-zoom card rendering |
| Boards switcher | ⌘K panel, 86×54 layout thumbnails, running/bell counts | None (single implicit strip) | Defer to M3 (strips); design is ready |
| Focus model | Typing always goes to focused terminal; ⌥tab cycles terminals only (HUD); docs never take focus; edit = borrowed focus, esc home | Focus rule already enforced (clicks never move focus off terminal) — single terminal | Principle already in place; HUD/cycle meaningful once multi-term lands (M2+) |
| Cockpit dock | ⏎ pins focused terminal to viewport bottom (`tm-dockpane`), dashed slot ghost on board, esc returns | None | New, after board core |
| Editing (v4c) | Doc cards become editors; conflict banner; honest `✎ you · editing` | Read-only `DocWebView` | Out of scope here — separate milestone |
| Window chrome | Custom titlebar w/ session chip + 27px status bar (board name, tmux state, counts) | Native titlebar, no status bar | Status bar in scope; session chip deferred to M3 strips |
| Persistence | Card frames, z-order, shelf membership, board viewport (pan+zoom) per strip | `layout {dock[], tiles[]}` slot order | Additive protocol keys (receivers already must ignore unknown keys) |

Unchanged and reusable: `DocWebView` + `DocTemplate.html` (restyle only),
`RecentMetaLabel` (`✎ Ns`), repo-dot color logic (swap palette), toast stack,
esc-priority handling, `DocStore` read/unread semantics, all daemon plumbing.

## 2 · Migration phases

Each phase ships a working app. Order minimizes rework: retheme first (pure
token swap), then the canvas (the load-bearing rebuild), then v4-specific
chrome in dependency order.

### Phase 0 — Crib + bundle refresh (docs only)
- v4 design files added to `design_handoff_tarmac/` (done — this commit).
- Write `docs/archive/v4/visual-crib.md` in the style of `docs/archive/m0/visual-crib.md`:
  Breeze token table (hex, no oklch conversion needed), card metrics
  (header 30px / radius 10 / pad 0 11px / shadow), dot grid (24px spacing,
  dot `#32383e`, offset −7,−9; 11px in lo-zoom), shelf/zoomctl/minimap/offhint
  metrics, locard metrics, edge stroke (`rgba(26,188,156,.5)` dash 3 5).

### Phase 1 — Breeze retheme (small, independently shippable)
- `Theme.swift`: replace all token values with breeze.css `:root` values;
  repo palette → Breeze hues; `liftBorder` → `#5a626a`.
- Terminal: `nativeBackgroundColor #31363b`, default fg `#ced2d6`,
  caret/cursor `#eff0f1`.
- `DocTemplate.html` + any view-hardcoded colors (doc body text `#ced3d7`).
- Acceptance: every surface matches breeze.css; no oklch leftovers; contrast
  spot-check on dock icons, unread dots, toasts.

### Phase 2 — Board core: infinite canvas + cards
The structural rebuild. Replace `DeskGridView`/`DeskLayout` with:
- `BoardView`: world↔view transform (pan via scroll/trackpad, zoom ⌘± /
  pinch anchored at pointer), dot-grid background drawn in board space.
- `CardView` (from `TileView`): world frame (x/y/w/h), z-order
  (select → front), header 30px, radius 10, `sel` handles, free drag-to-move
  (keep lift shadow; drop the −0.5° swap rotation or keep for drag style),
  corner-handle resize; terminal reflow once on resize end.
- Terminal card: SwiftTerm view embedded; zoom renders the card scaled
  (CALayer transform) — interactive only near 100%; that's acceptable, v4
  expects semantic zoom (Phase 4) for far-out work.
- Keyboard: esc priorities preserved (drag-cancel → peek → toasts).
- Persistence (additive protocol, `docs/protocol.md` receiver rules already
  permit): tiles gain `x,y,w,h,z`; new `board {zoom, cx, cy}`; daemon
  `persist.rs` round-trips them; restore reproduces exact layout+viewport.
- The 4-tile pin cap is removed (cap was a grid-template constraint). No
  hard card limit per board (DECISION 2026-06-13): perf is handled by
  offloading offscreen cards (pause doc rendering / snapshot far-out
  terminal cards), never by blocking the user.
- Acceptance: pinned docs from an M1 layout migrate (slot order → default
  scatter), pan/zoom/drag/resize persist across daemon+app restart.

### Phase 3 — Placement semantics: gravity, shelf, edges
- `tarmac open` lands a `fresh` card placed right of its caller terminal
  card (first free slot search), cyan ring + `✚ now` meta; esc moves the
  fresh card to the shelf. Replaces the M1 toast for `via:"cli"`.
- `ShelfView` (top-left overlay): chips with repo dot + basename + agent dot;
  click → peek; drag chip onto board → lands card. Shelf membership persisted.
- Remove `DockView`/`IndexView` + dock-birth path (cold-start "first doc"
  moment becomes the first card landing; shelf appears only when non-empty).
  Cold start keeps exactly the Cold Start Flow design (DECISION 2026-06-13):
  the one-line usage hint under the prompt, shown once — no empty-board
  placeholder, no replacement for the rail.
- Provenance edge layer beneath cards: dashed cyan bézier caller→doc with
  `tarmac open · HH:MM` label chip; survives both cards' drags; only drawn
  from the observable call record (which terminal ran `tarmac open` — with
  one terminal at this phase this is trivially the term card; carry the
  caller `term_id` in the protocol so Phase 5 multi-term attribution slots in).
- Gravity drag: dragging a terminal card translates its satellite doc cards
  (docs it opened, while they remain untouched-by-user); manually-moved cards
  detach (owner chip `← claude` / loose).
- Peek ⌘⏎: "land as card at gravity position" (replaces pin); peek itself
  unchanged.
- Status bar (27px, mono 10.5): left `▞ <strip> · board`, right counts
  (`N cards on board · M in shelf`).
- Acceptance matches mock B2: land → drag elsewhere → restart → positions and
  edges intact.

### Phase 3.5 — M2 honest signals (pulled forward; DECISION 2026-06-13)
Mostly daemon-side and orthogonal to the visual work, but Phase 4's chrome
is built around its outputs (bell, foreground process name, exit). Land the
M2 milestone here so the wayfinding views are written against real signals
instead of degraded cyan-only placeholders: `tcgetpgrp` process names on
terminal card headers, BEL detection (amber), exit toast.

Scope shift vs the v3 M2 plan: "tab label = process name" becomes "card
title = process name", and the v3 rail (processes + file events) is
superseded by card-header signals plus the Phase 4 wayfinding chrome — no
rail is built.

### Phase 4 — Wayfinding: zoom control, minimap, offscreen hints, semantic zoom
- Zoom control bottom-left (`− / % / + / ⊡ fit`); fit = bounding box of cards.
- Minimap bottom-right 132×88: card rects (cyan = agent-active, amber = bell),
  viewport rect, click-to-jump.
- Offscreen signal pills pinned to the viewport edge toward the source card
  (`✎ runbook.md · 13:58`, arrow); ⏎ flies viewport to the card, esc flies
  back; bell (amber) and live (cyan) variants.
- Semantic zoom: below ~50% swap card content for the locard rendering —
  name + kind glyph + signal line, hide body; denser grid (11px). Terminal
  cards show foreground process name + duration.
- Acceptance matches mocks B3/B4.

### Phase 5 — Terminal primacy: prime styling, cockpit dock
- `prime` (focused terminal: border `#5a626a`, header `#3a4046`, deeper
  shadow) and `quiet` (opacity .8) card states.
- Cockpit dock: ⏎ (when board-focused) docks the focused terminal to a
  viewport-fixed bottom pane (`tm-dockpane`, top border `#5a626a`), dashed
  slot ghost at its board position, esc returns it. Board pans behind.
- Multiple terminal cards (the v4 successor to v3-M2's tabs/splits — splits
  are gone, the card is the unit): ⌘T spawns a new shell card on the board;
  the protocol already keys spawn/input/resize/exit by `term_id`, the daemon
  needs concurrent pty sessions; Phase 3.5 signals (process name, bell,
  exit) render per card.
- ⌥tab terminal-only cycle + top-center HUD (meaningful from 2 terminals up);
  focus model now does real work — typing goes to the prime terminal
  regardless of pointer position.
- Provenance attribution becomes real here: each `tarmac open` records its
  calling `term_id`, so edges and gravity bind to the right terminal card.
- Acceptance matches mocks F1/F3.

### Deferred (tracked, not in this migration)
- **Boards switcher ⌘K + per-strip boards** → M3 (strips/tmux); design B5 ready.
- **Editable docs / conflict banner (v4c)** → milestone after M3 (needs the
  write-signal honesty model). The captured design spec is
  [`docs/v4c/visual-crib.md`](../../v4c/visual-crib.md) — transcribed from the
  v4c handoff mocks (`board-v4c.jsx` rules board + E1/E2 mocks, `board.css` §v4c
  `.edit`/`.tm-caret`/`.tm-homechip`/`.tm-conflict`) and `chat2.md` before the
  `design_handoff_tarmac/` bundle was removed (originals in git history). Core
  invariants decided in design:
  *focus's home is the terminal* (editing = borrowed focus, esc always goes
  home, ⌥tab still cycles terminals only), gravity unchanged by editing, your
  save is just another file event (`✎ you · editing` vs `✎ Ns · during
  claude`), and write conflicts are reported (mtime fact + diff/reload/keep)
  — never arbitrated.

  How to drive it when M3 is done (same loop as this migration):
  1. **Design round first** — v4c is only 2 mocks + a rules board; chat2
     ends with open questions the mocks don't answer: diff view shape
     (in-card split vs a new diff card — explicitly flagged as "next step"),
     edit mode (rendered/WYSIWYG vs source — `EditDocBody` hints rendered
     text with a caret, undecided), save semantics (autosave vs ⌘S; the
     conflict banner assumes an "unsaved changes" state exists), and whether
     peek/shelf docs are editable. Continue the claude.ai/design project,
     re-export.
  2. **Fetch + diff the new bundle** against the v4c mocks preserved in git
     history (removed with `design_handoff_tarmac/` once captured).
  3. **Update [`docs/v4c/visual-crib.md`](../../v4c/visual-crib.md)** — already
     captured from the original mocks — with whatever the refreshed export changes.
  4. **Implement in three layers**: (a) edit-state chrome + borrowed-focus
     mechanics (cheap — card ring, caret, `⌂ esc` chip, esc-home routing);
     (b) the editor surface itself — the big tech decision: `DocWebView` is
     a read-only WKWebView, so editable means contenteditable/CodeMirror in
     the webview vs a native text view; (c) conflict banner + diff exit.
  5. **Daemon: near-zero** (chat2's conclusion — no new signal kinds;
     conflict = existing mtime watch ∩ app-local unsaved-edit state). Only
     open item: attributing a file event to *your own just-saved write* so
     meta can say `✎ you` — app-side bookkeeping, decide in the crib.
- **Zone labels** (user-typed board text) → nice-to-have after Phase 4.
- **Titlebar session chip** → M3 (session naming is a strips concept).

## 3 · Resolved decisions (2026-06-13)
1. **No hard card cap per board** — perf via offscreen offloading, never by
   blocking the user (Phase 2).
2. **Cold start stays the one-line prompt hint** — nothing replaces the dock
   rail (Phase 3).
3. **M2 honest signals pulled forward** between Phases 3 and 4 (Phase 3.5),
   so wayfinding is built against real bell/process/exit signals.

## 4 · Milestone mapping (v3 plan → after this migration)

| v3 milestone | Fate |
| --- | --- |
| M0 walking skeleton | Shipped; untouched. |
| M1 doc three-states (dock/peek/pin) | Shipped; its grid/dock/pin **visuals** are replaced by Phases 2–3, its state semantics (DocStore, read/unread, `✎ Ns`, peek) carry over. |
| M2 honest signals | Absorbed as Phase 3.5 (scope shift noted there: card titles instead of tab labels, no rail). |
| — multi-terminal (was M2 tabs/splits) | Reshaped as multiple terminal cards; lands in Phase 5. |
| M3 strips (tmux, restore, ⌘K) | **Still the next milestone after this migration**, reshaped as *strips = boards*: tmux attach/detach, session restore now restores per-board card layout + viewport, ⌘K becomes the boards switcher (design B5), titlebar session chip. |
| — editable docs (v4c, design 05) | New milestone after M3 — needs the write-signal honesty model. |

**Definition of done for this migration:** the single-board whiteboard
experience is complete — Breeze theme, infinite canvas with persisted
layout, gravity/shelf/provenance, honest signals, wayfinding, terminal
primacy (incl. multiple terminal cards and cockpit dock). Multi-board
(strips) and doc editing are intentionally out.
