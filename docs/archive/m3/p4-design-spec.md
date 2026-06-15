# P4 design spec — extracted from the design refs (board-v4.jsx B5, parts.jsx, theme.css, board.css)

Visual source of truth for P4 (⌘K boards switcher + titlebar session chip + status-bar
board state). All numbers/colors quoted verbatim from
`design_handoff_tarmac/tarmac/{board-v4.jsx,parts.jsx,theme.css,board.css}`.
Tarmac uses NSColor approximations of these oklch/hex tokens via `Theme.swift` — map
to existing `Theme` tokens where they already exist; only add a token if missing.

## Palette tokens (theme.css `:root`)
- `--tm-bg0  #0c0e12` window backdrop / thumbnail bg
- `--tm-bg1  #12151a` pane / titlebar / statusbar bg
- `--tm-bg2  #191d24` raised — switcher panel bg, session chip bg
- `--tm-bg3  #20252e` hover — selected row bg (`.tm-brow.on`), thumb neutral rect bg
- `--tm-line #262c36`, `--tm-line-soft #1d222b`
- `--tm-text #d8dbe2`, `--tm-muted #8c93a0`, `--tm-faint #5a616d`
- `--tm-agent oklch(0.78 0.11 200)` cyan (live), `--tm-amber oklch(0.78 0.11 75)` bell
- `--tm-ok oklch(0.75 0.1 150)` green (attached)
- mono font: IBM Plex Mono → `Theme.mono(...)`

## ⌘K switcher panel — `.tm-boards`
- `position: absolute; left:50%; top:72px; transform:translateX(-50%)` → centered horizontally, **72px from top**.
- `width: 540px`; `background: bg2`; `border: 1px solid line`; `border-radius: 12px`;
  `box-shadow: 0 24px 60px rgba(0,0,0,0.6)`; `overflow: hidden`; mono; left-aligned.
- z-index 6 (above the veil at z 5).

### Header `.bhead`
- flex, `gap:9px`, `padding:12px 16px`, `border-bottom: 1px solid line-soft`, `font: 400 12px mono`, color `faint`.
- Content: `▞ ` + `<span class=q>boards</span>` (q = color `text`) + `<span opacity:0.6>— type to filter</span>`.

### Row `.tm-brow`
- flex, `align-items:center`, `gap:13px`, `padding:11px 16px`.
- Selected: `.tm-brow.on { background: bg3 }`.
- Children in order: thumbnail (`.tm-bthumb`), name (`.nm`), meta (`.meta`).
- `.nm`: `font: 500 12px mono`, color `muted`; `.on .nm` → color `text`; flex gap 8.
  - glyph `▞` colored `agent` (cyan) when live; **faint** when detached (B5 billing-fire row).
  - then the board name.
- `.meta`: `margin-left:auto`, `font: 400 10px mono`, color `faint`, flex gap 10.
  - Running board: `⠧ 2 running · 1 bell · 8 cards` (⠧ spinner in agent cyan; "N running", "M bell" only when >0).
  - `1 running · 3 cards` (no bell segment when 0).
  - Detached/bell board: `● bell 12m · 4 cards` (`●` amber, no running spinner).

### Footer `.bfoot`
- `padding:9px 16px`, `border-top: 1px solid line-soft`, `font: 400 10px mono`, color `faint`, flex gap 14.
- `⏎ open board` · `⌘1-9 jump` · `n new board`.

### Thumbnail `.tm-bthumb` (the 86×54 mini-projection)
- `width:86px; height:54px; flex:none; position:relative`.
- `background: bg0; border: 1px solid line; border-radius: 6px;`
  `background-image: radial-gradient(#1d222b 0.8px, transparent 1px); background-size: 9px 9px;` (dot grid).
- `overflow: hidden`.
- Each tile = `<i>` absolutely positioned (left/top/width/height px **within the 86×54 box**):
  - neutral (doc / non-live): `background: bg3; border: 0.5px solid line; border-radius:1.5px`.
  - `.cy` (live term): `background: oklch(0.78 0.11 200 / 0.55); border-color: transparent`.
  - `.am` (bell): `background: oklch(0.78 0.11 75 / 0.7); border-color: transparent`.
- Tiles are a **static projection of the board's tile world-frames into the 86×54 box** — NOT live views.
  Derivation (to extract + unit-test in TarmacKit): compute the board's world bounding box over its
  tile frames, scale uniformly to fit inside 86×54 (with a small inset/padding), map each tile rect.
  Color = live-term→cy, bell→am, else neutral.

## Veil `.tm-veil`
- `position:absolute; inset:0; background: rgba(8,10,13,0.62); z-index:5;` — darkens the board behind the panel.
- Behind it, board cards get `.dim { opacity: 0.55 }`.

## TitleBar (`parts.jsx` TitleBar/Lights + theme.css)
- `.tm-titlebar { height:40px; bg1; border-bottom:1px solid line-soft; flex gap:10px; padding-right:12px }`.
- Layout L→R: Lights (traffic lights) · session chip · doc tabs · right cluster (ProcChip).
- `.tm-lights { gap:8px; padding:0 6px 0 14px } i{12×12 circle}` colors r `#ec6a5e` y `#f4bf4f` g `#61c454`;
  **dim mode** `.tm-lights.dim i { background:#3a414c }` (all three go gray in ⌘K).
- Session chip `.tm-session`: `font:500 11px mono; color:muted; padding:3px 8px; radius:5px; bg2;
  border:1px solid line-soft; white-space:nowrap`. Content `▞`(glyph color agent, weight 600) + session name.
- B5 passes `dim` to the whole TitleBar in ⌘K (lights dim; chip can dim too).
- NOTE: native app titlebar today is plain NSWindow chrome. Plan: adopt `fullSizeContentView`
  + a transparent `NSTitlebarAccessoryViewController`/accessory hosting the chip. The traffic
  lights are the real macOS window buttons — "dim in ⌘K" maps to dimming our accessory + optionally
  the standardWindowButtons.

## StatusBar (`parts.jsx` StatusBar + theme.css `.tm-status`)
- `height:27px; bg1; border-top:1px solid line-soft; padding:0 12px; font:400 10.5px mono; color:faint; gap:14px`.
- `.l` (left cluster) + `.r` (right, margin-left:auto).
- Left in B1–B4: `▞ infra-week · board` (▞ agent cyan) AND `tmux attached` (attached = `--tm-ok` green) — the
  tmux word is P5 (session liveness); P4 left cluster = board name + count.
- **B5 left cluster: just `▞ infra-week · board`** (no tmux line while switcher open).
- Right: free-form counts; B5 right = `3 boards`.
- Tarmac's `StatusBar.swift` already added `setBoard(name, count)` in P3 → `▞ board-3 · N boards`.
  P4 keeps/uses that; the name should prefer the display name over the slug.

## Keyboard contract (B5 footer + plan §P4)
- ⌘K toggles the switcher (capture keys; board behind inert).
- type-to-filter: prefix match on board name (fuzzy deferred).
- ⏎ opens the selected/only board (BoardSwitch).
- ⌘1..9 jump to board by **row/order** index (BoardSwitch).
- `n` creates a new board (BoardCreate) and switches to it.
- ↑/↓ move selection; esc dismisses without switching.
