# Tarmac v4 (Whiteboard) — visual crib

Exact values for the Swift/AppKit implementer of Phases 0–2. Sources:
`design_handoff_tarmac/tarmac/breeze.css` (canonical Breeze token sheet + chrome
overrides), `board.css` (board/card/chrome geometry), `board-v4.jsx` + `canvas-v4.jsx`
(component structure & world frames), layered over `theme.css` + `converged.css`.
v4 is the **Ghostty Breeze** retheme of the M0/M1 dark palette; every hex here is
authored sRGB — no oklch conversion needed (Breeze writes hex directly; the few
oklch literals left in `board.css` have rgba overrides in `breeze.css`, listed below).

AppKit: `NSColor(srgbRed:green:blue:alpha:)` — not `calibratedRed`. Where `board.css`
writes a literal hex AND `breeze.css` re-derives it, `breeze.css` wins (it loads last
as the "hardcoded chrome colors … re-derived" layer); both are shown.

## 1 · Breeze color tokens

`:root` set + every hardcoded chrome color in `breeze.css`. All hex sRGB.

| Token | Breeze hex | rgb | Use |
|---|---|---|---|
| `--tm-bg0` | `#24282c` | 36 40 44 | board backdrop — one step under breeze bg; resize handle fill; edge-label chip bg |
| `--tm-bg1` | `#2b3036` | 43 48 54 | card pane; shelf chip bg |
| `--tm-bg2` | `#353b41` | 53 59 65 | raised / headers (`.bhd`); shelf / zoomctl / offhint / cyclehud bg |
| `--tm-bg3` | `#3e444b` | 62 68 75 | hover; minimap card rect default; boards-row `.on` |
| `--tm-term-bg` | `#31363b` | 49 54 59 | terminal body (Ghostty bg verbatim); dockpane |
| `--tm-line` | `#474e55` | 71 78 85 | card / chrome borders |
| `--tm-line-soft` | `#3d434a` | 61 67 74 | hairlines (`.bhd` bottom border, chip border) |
| `--tm-text` | `#eff0f1` | 239 240 241 | primary text (Ghostty fg); zoom `.pct`; caret/cursor |
| `--tm-muted` | `#b9bfc4` | 185 191 196 | secondary text (`.bhd` label, offhint, shelf chip) |
| `--tm-faint` | `#7f8c8d` | 127 140 141 | tertiary / hints (kind glyph, shelf, owner, edge label); ANSI bright-black |
| `--tm-agent` | `#1abc9c` | 26 188 156 | cyan — agent signal everywhere; sel/fresh/edit border; handle border |
| `--tm-agent-dim` | `rgba(26,188,156,0.16)` | 26 188 156 @ 0.16 | tints, rings (fresh/edit), minimap viewport fill |
| `--tm-amber` | `#fdbc4b` | 253 188 75 | bell / waiting; ANSI bright-yellow |
| `--tm-amber-dim` | `rgba(253,188,75,0.16)` | 253 188 75 @ 0.16 | amber tints (locard bell ring, conflict banner) — **new; no `amberDim` in Theme.swift** |
| `--tm-ok` | `#1cdc9a` | 28 220 154 | success / exit 0; ANSI bright-green |
| `--tm-repo-a` | `#f67400` | 246 116 0 | repo dot — orange |
| `--tm-repo-b` | `#11d116` | 17 209 22 | repo dot — green |
| `--tm-repo-c` | `#1d99f3` | 29 153 243 | repo dot — blue |
| `--tm-repo-d` | `#9b59b6` | 155 89 182 | repo dot — purple |

Hardcoded chrome colors (`breeze.css` overrides; not `:root` tokens):

| Selector / role | Breeze value | rgb | Note |
|---|---|---|---|
| `.tm-win` window border | `#16181b` | 22 24 27 | 1px window edge, darker than bg0 — **no Theme.swift token** |
| `.tm-board` dot grid | `#32383e` | 50 56 62 | radial-gradient dot color — **no Theme.swift token** |
| `.tm-bthumb` dot grid | `#32383e` | 50 56 62 | switcher thumbnail dots (same hex) |
| `.tm-doc p / ul` prose | `#ced3d7` | 206 211 215 | doc body paragraphs/lists — distinct from text/muted (M0 had a `prose` token) |
| `.tm-bcard.prime` border | `#5a626a` | 90 98 106 | = lift/dockpane border value |
| `.tm-bcard.prime .bhd` bg | `#3a4046` | 58 64 70 | prime header, near bg2 but distinct |
| `.tm-tile.lift / .tm-dockpane` border | `#5a626a` | 90 98 106 | **maps to `liftBorder`** (was `#39414e`) |
| `.tm-minimap` bg | `rgba(36,40,44,0.92)` | bg0 @ 0.92 | (board.css writes `rgba(12,14,18,0.92)`; breeze override wins) |
| `.tm-minimap .mr.cy` | `rgba(26,188,156,0.8)` | agent @ 0.8 | minimap agent-active rect |
| `.tm-minimap .mr.am` | `rgba(253,188,75,0.85)` | amber @ 0.85 | minimap bell rect |
| `.tm-edges path` stroke | `rgba(26,188,156,0.5)` | agent @ 0.5 | provenance edge (board.css/jsx oklch @ 0.45; breeze override @ 0.5 is the crib target) |
| `.tm-locard.bell` border | `rgba(253,188,75,0.55)` | amber @ 0.55 | |
| `.tm-locard.live` border | `rgba(26,188,156,0.45)` | agent @ 0.45 | |
| `.tm-offhint.bell` border | `rgba(253,188,75,0.5)` | amber @ 0.5 | |
| `.tm-offhint.live` border | `rgba(26,188,156,0.4)` | agent @ 0.4 | |
| `.tm-bthumb i.cy` | `rgba(26,188,156,0.6)` | agent @ 0.6 | switcher mini agent rect |
| `.tm-bthumb i.am` | `rgba(253,188,75,0.7)` | amber @ 0.7 | switcher mini bell rect |

All minimap / edge / locard / offhint / bthumb accents are alpha composites of the
agent (`#1abc9c`) and amber (`#fdbc4b`) bases — derive at runtime, don't bake hex.

## 2 · Phase 1 token-swap table (Theme.swift)

Per `migration-plan.md` Phase 1: replace **every** `Theme.swift` value with its Breeze
counterpart; repo palette → Breeze hues; `liftBorder → #5a626a`. Current hex from
`Theme.swift`; target from `breeze.css :root`.

| Symbol | Current (M0/M1) | → Breeze | Note |
|---|---|---|---|
| `bg0` | `#0c0e12` | `#24282c` | |
| `bg1` | `#12151a` | `#2b3036` | |
| `bg2` | `#191d24` | `#353b41` | |
| `bg3` | `#20252e` | `#3e444b` | |
| `termBg` | `#0a0c10` | `#31363b` | Ghostty bg verbatim |
| `line` | `#262c36` | `#474e55` | |
| `lineSoft` | `#1d222b` | `#3d434a` | |
| `text` | `#d8dbe2` | `#eff0f1` | Ghostty fg |
| `muted` | `#8c93a0` | `#b9bfc4` | chrome muted (NOT terminal muted — see §3) |
| `faint` | `#5a616d` | `#7f8c8d` | |
| `agent` | `#4eccd3` | `#1abc9c` | |
| `agentDim` | `#4eccd3` @ 0.16 | `#1abc9c` @ 0.16 | `srgb(0x1abc9c, alpha: 0.16)` |
| `liftBorder` | `#39414e` | `#5a626a` | authored hex, not a `:root` token |
| `amber` | `#e1ad63` | `#fdbc4b` | |
| `ok` | `#7fc08c` | `#1cdc9a` | |
| `repoColors[0]` (repo-a) | `#d78e88` | `#f67400` | orange |
| `repoColors[1]` (repo-b) | `#81b482` | `#11d116` | green |
| `repoColors[2]` (repo-c) | `#89a4de` | `#1d99f3` | blue |
| `repoColors[3]` (repo-d) | `#be92c8` | `#9b59b6` | purple |

Repo palette order is unchanged: index 0..3 = `repo-a..d` = orange `#f67400` /
green `#11d116` / blue `#1d99f3` / purple `#9b59b6`. `repoColor(for:)` FNV-1a hash and
`repoColor(index:fallbackName:)` are unchanged — only the four hexes change.

**New tokens Breeze needs that `Theme.swift` lacks** (add as Phase 1+ surfaces require):
`amberDim` = `srgb(0xfdbc4b, alpha: 0.16)`; dot-grid color `#32383e`; window border
`#16181b`; doc prose `#ced3d7`; prime header bg `#3a4046`; terminal-interior muted
`#ced2d6` (§3). The agent/amber alpha derivatives (minimap, edges, locard, offhint,
bthumb) are computed from `agent`/`amber` at the alphas in §1 — not separate symbols.

## 3 · Terminal interior

Terminal surfaces use the **exact** Ghostty Breeze values; chrome muted does NOT apply
inside the terminal. `breeze.css` scopes an override on `.tm-term, .tm-tbody,
.tm-dockpane, .tm-drawer, .tm-doc pre`:

| Role | Value | rgb | Source |
|---|---|---|---|
| term bg | `#31363b` | 49 54 59 | `--tm-term-bg` (Ghostty bg) — `nativeBackgroundColor` |
| default fg / output | `#ced2d6` | 206 210 214 | scoped `--tm-muted` override (NOT `:root` muted `#b9bfc4`) |
| emphasized text | `#eff0f1` | 239 240 241 | scoped `--tm-text` (= `:root` text) |
| caret (`.tm-caret`) | `#eff0f1` | 239 240 241 | `cursor-color` |
| cursor (`.tm-cursor`) | `#eff0f1` | 239 240 241 | block cursor bg |

Phase 1: SwiftTerm `nativeBackgroundColor #31363b`, default fg `#ced2d6`, caret/cursor
`#eff0f1`. ANSI accents map to tokens: cyan `#1abc9c`, bright-green `#1cdc9a`,
bright-yellow `#fdbc4b`, bright-black `#7f8c8d`.

## 4 · Card metrics (`.tm-bcard`)

Free card on the board. Replaces `TileView` → `CardView` (`board-v4.jsx` `BCard`:
world frame `style={{ left:x, top:y, width:w, height:h }}`).

- Position `absolute`, `z-index 1`; `display flex; flex-direction column`;
  `overflow hidden`.
- Background `bg1 #2b3036`; border `1px solid line #474e55`; **radius 10px**.
- Shadow `0 16px 38px rgba(0,0,0,0.5)`.
- Header `.bhd`: **height 30px**, padding `0 11px`, gap 7px, `flex none`;
  bg `bg2 #353b41`; bottom border `1px solid line-soft #3d434a`;
  font `400 10.5px mono`, color `muted #b9bfc4`.
  - `.kind` glyph color `faint #7f8c8d`; term glyph `›_`, doc glyph `¶`, check `✓`.
  - `.mr` right cluster: `margin-left auto; display flex; align-items center; gap 8px`.
  - doc header right meta font `400 9.5px mono`.
- Body (`TermCardBody`): `flex 1`; bg `term-bg #31363b`; padding `10px 14px`;
  font-size 11.5px.

Variants:

| Variant | Border | Shadow / extra |
|---|---|---|
| `sel` | `agent #1abc9c` | base shadow only **+ 4 corner handles** (below) |
| `fresh` (just-spawned) | `agent` | `0 0 0 3px agent-dim, 0 16px 38px rgba(0,0,0,.5)` (cyan ring 3px) |
| `dim` | base | `opacity 0.55` |
| `prime` | `#5a626a` | `0 22px 50px rgba(0,0,0,0.6)`; `.bhd` color `text`, bg `#3a4046` |
| `quiet` | base | `opacity 0.8` |
| `edit` | `agent` | `0 0 0 2px agent-dim, 0 16px 38px rgba(0,0,0,.5)` (cyan ring 2px); `.bhd` color `text` |

`.owner` chip (prime/quiet header): `400 9px mono`, color `faint`, `1px solid
line-soft` border, radius 4, padding `1px 6px`.

Selected-card resize handles (`.hndl`, rendered only when `sel`, 4 = one per corner):
**7×7px**, fill `bg0 #24282c`, border `1.5px solid agent`, radius 2px, `z-index 3`.
Offsets in `board-v4.jsx`: each corner at `-4` (TL `left:-4 top:-4`, TR `right:-4
top:-4`, BL `left:-4 bottom:-4`, BR `right:-4 bottom:-4`) — handle spans `-4..+3`, i.e.
~4px outside the edge. **`.tm-bcard` is `overflow:hidden`**, so handles must live on a
non-clipped outer layer (the native port already splits outer border layer from inner
clip — put handles on the outer layer; do not clip them).

Contrast vs current `TileView`:

| Metric | Current TileView | v4 `.bcard` | Δ |
|---|---|---|---|
| header height | 28px | 30px | +2 |
| corner radius | 9 | 10 | +1 |
| header padding-x | 10 | 11 | +1 |
| header font | mono 10.5 | mono 10.5 | — |
| header gap | 7 | 7 | — |
| border | 1px `line` | 1px `line` | — (color value changes per §2) |
| terminal body padding | 16h / 12v | 14h / 10v | −2 / −2 |
| corner resize handles | none | 4 × 7px (agent, r2, off −4) | new |

(Current `TileView` had no resize handles — only `DashedBorderView` drop target,
radius 8.25 inset, 1.5px stroke `[4.5,4.5]` dash. v4 drops the swap drop-target; adds
move + handle resize.)

## 5 · Board + dot grid + world↔view transform

Board `.tm-board`: `position relative; flex 1; min-height/width 0; overflow hidden`;
background `bg0 #24282c`.

Dot grid: `background-image: radial-gradient(#32383e 1px, transparent 1.3px)`
(solid to 1px, feather to 1.3px ≈ 2px dot). Spacing `24px 24px`, phase/offset
`-7px -9px`. Lo-zoom (`.tm-board.lo`) spacing `11px 11px` (denser). Dot color
**`#32383e`** is the canonical Breeze value (per migration plan + `breeze.css`;
`board.css` literal `#1d222b` is the un-rethemed source, ignore it).
Switcher thumbnail (`.tm-bthumb`) grid: dot `#32383e`, stops `0.8px / 1px`,
spacing `9px 9px`.

World frames: each card stores **world-space** `x, y, w, h` (`board-v4.jsx` maps them
straight to `left/top/width/height`). The JSX mockups are **static** — coordinates are
already in view space at the labelled zoom; there is **no** pan/zoom matrix or world→view
function in the design sources, and **no min/max zoom bounds** are specified anywhere
(observed display values span 36%–100%). The real transform is built in Swift
(`BoardView`, Phase 2):

- **Pan**: scroll / trackpad.
- **Zoom**: `⌘±` / pinch, anchored at the pointer.
- Persisted viewport: `board {zoom, cx, cy}` (center x/y + zoom) per strip (§9).
- Apply `view = (world − center) · zoom + viewportCenter`; cards positioned by world
  frame, the whole card layer transformed by pan+zoom.

Fresh-card spawn placement (`tarmac open`, Phase 3 / B2Spawn): fresh card lands **right
of the caller terminal card**, "first free slot search". The single B2 mockup is
illustrative, not a formula: caller term `x=92 y=108 w=470 h=330` (right edge x=562);
fresh card `x=648 y=140 w=392 h=310` → ~86px horizontal gap past the caller's right
edge, +32px below the caller top. Fresh card gets the cyan ring (§4 `fresh`) and a
`✚ now` meta in agent cyan (`400 9.5px mono`); `esc` moves it to the shelf. **Treat
86px/32px as illustrative — the rule is "first free slot to the right," not fixed
constants.**

## 6 · Board chrome (shelf / zoom control / minimap / offscreen hint)

Capture now; built in Phase 4 (except shelf, Phase 3). All `position absolute`.
Shared shadow `0 8px 22px rgba(0,0,0,0.45)` (offhint uses `…0.5`).

**Shelf** `.tm-shelf` (top-left open-but-unplaced docs; replaces the dock):
`left 12 top 12 z 5`; `flex; align-items center; gap 6px`; bg `bg2`, border `1px line`,
radius 9, padding `5px 9px`; font `400 9.5px mono`, color `faint`. Label text `SHELF`.
`.chip`: `flex; align-items center; gap 6px`; font `400 10px mono`, color `muted`;
bg `bg1`, border `1px line-soft`, radius 6, padding `3px 8px`, `white-space nowrap`;
each chip = repo dot + filename (e.g. `plan.md`, `notes.md`).

**Zoom control** `.tm-zoomctl` (bottom-left): `left 12 bottom 12 z 5`;
`flex; align-items stretch`; bg `bg2`, border `1px line`, radius 8, `overflow hidden`;
font `400 10.5px mono`, color `faint`. `span`: padding `6px 9px; flex; align-items
center`. `.pct` (the % readout): color `text`, `border-left`+`border-right 1px
line-soft`, padding `6px 10px`. Contents L→R: `−` (U+2212) · `[pct]` · `+` · `⊡ fit`
(U+22A1, fit span has a `border-left 1px line-soft`). Demo zoom values: 82% / 100% /
36% / 100% (B1–B4). Fit = bounding box of all cards.

**Minimap** `.tm-minimap` (bottom-right): `right 12 bottom 12 z 5`; **width 132px,
height 88px**; `overflow hidden`; bg `rgba(36,40,44,0.92)` (bg0 @ 0.92), border `1px
line`, radius 8. `.mr` card rect: `absolute`, bg `bg3 #3e444b`, radius 1.5px;
`.mr.cy` = `rgba(26,188,156,0.8)` (agent-active), `.mr.am` = `rgba(253,188,75,0.85)`
(bell). `.vp` viewport rect: `1px solid agent` border, radius 2px, bg `agent-dim`.
(B1 vp `x36 y22 w62 h40`; B3 vp `x14 y10 w104 h66` — illustrative.)

**Offscreen hint** `.tm-offhint` (pinned to viewport edges): `z 6`; `flex; align-items
center; gap 7px`; bg `bg2`, border `1px line`, **radius 999px (pill)**, padding
`6px 11px`; font `400 10.5px mono`, color `muted`; shadow `0 8px 22px rgba(0,0,0,0.5)`.
`.arr` (direction arrow `→ ← ↑`) color `faint`. Variants: `.bell` border
`rgba(253,188,75,0.5)`, color `text`, `.arr` color `amber`; `.live` border
`rgba(26,188,156,0.4)`. (B4 examples: bell `right:10 top:230`, left `left:10 top:310`,
live `left:470 top:48`.)

## 7 · Locard / semantic zoom (`.tm-locard`)

Below the readability threshold (`migration-plan.md` Phase 4: **~50%**), cards swap to
the locard rendering — "content gone, name + signal remain" — and the board gets class
`.lo` (denser 11px dot grid; `.tm-zonelab` font 10px → 13px). The exact threshold is
**not** a literal in the design sources: locards appear at z=36% (B3), full cards at
z≥82% (B1); ~50% is the migration plan's stated midpoint. No numeric constant exists in
`board.css`/`board-v4.jsx`.

`.tm-locard`: `absolute; z 1`; bg `bg1`, border `1px solid line`, **radius 8px**;
`flex; flex-direction column; justify-content center; gap 5px; padding 0 14px`;
font-family mono; shadow `0 10px 24px rgba(0,0,0,0.4)`. Renders exactly two children:
- `.nm` (name row): `flex; align-items center; gap 7px`; font `500 12px mono`, color
  `text`, `white-space nowrap`. Holds `.kind` glyph (color `faint`, weight 400) +
  optional repo dot + name.
- `.st` (status row): font `400 9.5px mono`, color `faint`. One signal line.

Variants: `.bell` border `rgba(253,188,75,0.55)` + ring `0 0 0 3px amber-dim, 0 10px
24px rgba(0,0,0,.4)`; `.live` border `rgba(26,188,156,0.45)`. No width/height in CSS —
both from world `w/h` (B3 examples cluster w 170–222, h 56–64).

## 8 · Provenance edges (`.tm-edges`)

SVG layer **under** cards: `position absolute; inset 0; z-index 0; pointer-events none;
width/height 100%`. Drawn from observable facts only (caller terminal card → doc card).

Each edge is a single cubic bézier `M start C cp1, cp2, end` (`board-v4.jsx` `Edge`,
prop `d`), with both control points biased horizontally toward the destination (small
`dy`, larger `dx`) → a gentle near-horizontal left→right swoosh from the caller's right
edge to the doc card's left edge. Path attributes (inline on `<path>`):

- stroke `rgba(26,188,156,0.5)` (Breeze override; JSX/board.css authored oklch @ 0.45 —
  use the rgba @ 0.5 crib target)
- `stroke-width 1.2`, `stroke-dasharray 3 5`, `fill none`.

Example `d`: `M 508 208 C 560 218, 562 230, 606 244` (B1, dx 98 / dy 36);
`M 562 268 C 608 276, 612 282, 648 290` (B2). Control points are authored ad-hoc per
edge — no formula in source; pick control points that keep the curve near-horizontal.

Label chip `.tm-edgelab` (optional, passed per edge at `lx/ly`): `absolute; z-index 0;
pointer-events none` (sits behind cards); font `400 9px mono`, color `faint`, bg `bg0`,
padding `1px 6px`, radius 4. Text e.g. `tarmac open · 14:02` (`·` = U+00B7).

## 9 · Phase 2 persistence — additive protocol keys

**Additive only** — new OPTIONAL keys per `docs/protocol.md` encoding rules (decoders
ignore unknown keys; optional = nil-or-omitted; missing key ⇒ nil). All 7 conformance
vectors and M1 frames MUST still decode unchanged.

**Tile** (`restore.tiles[]` and `layout.tiles[]`) gains optional world-frame keys:

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `x` | float | nil | world-space left |
| `y` | float | nil | world-space top |
| `w` | float | nil | world-space width |
| `h` | float | nil | world-space height |
| `z` | int | nil | stacking order (z-index) |

`kind` stays required; receivers still skip unknown `kind` and ignore unknown keys.
A tile with no `x/y/w/h/z` behaves exactly as an M1 tile (app falls back to grid
placement) — so M1 frames decode identically.

**`restore` / `layout`** gain an optional `board` map (per strip — the persisted board
viewport):

| key | type | missing ⇒ | semantics |
|---|---|---|---|
| `board.zoom` | float | nil | viewport zoom factor |
| `board.cx` | float | nil | viewport center x (world) |
| `board.cy` | float | nil | viewport center y (world) |

Whole `board` map missing ⇒ nil (app uses a default viewport). `persist.rs` round-trips
`x,y,w,h,z` and `board {zoom,cx,cy}`; restore reproduces the exact layout + viewport.
No new message types, no new signal kinds — additive keys only.
