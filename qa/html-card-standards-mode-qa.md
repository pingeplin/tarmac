# QA — HTML card standards mode (#214, spec 2610.0011)

The live half of [spec 2610.0011](../.blueprint/specs/2610.0011_html_card_standards_mode.md):
its `[QA]` scenarios, with the values observed. The unit scenarios are
`ShimPlacementTests`, `CardProtocolTests` and `CardSchemeRouterTests`; the
guide and architecture scenarios are commands, listed in the spec.

It is also the §1.3 exception-4 discharge for the comment changes in
`card_shim.js`, `HTMLCardView.swift` and the probe pages under `qa/`.

**Run:** 2026-10-10, macOS 26.7 (25G229). Two debug builds, one after the other
(one dev app at a time), each from `make run DEV_DIR=<new dir under .dev/>`:

- **Before:** the tree `225-html-card-font-variables`, clean, at `538508e` (the
  base of this branch). pid 70218.
- **After:** this branch, `fix/214-html-card-standards-mode` on `538508e` plus
  the **uncommitted working tree** (the implementation, the spec, these files).
  pid 91448 for everything except S32; pid 50437 for S32 (a relaunch with the
  scroll bar setting, below).

Both windows: 1100 x 732 at global (730, 189) on the 2560 x 1440 display at 1x
(a 196 x 155 point card region captures as 196 x 155 pixels), visible, the
screen unlocked (`CGSSessionScreenIsLocked` absent). The channels started with
no state: a boot terminal, Terminal 16, Document 14, both families System
Default, theme Dark (`ThemeChoice.standard`). The after app opened on the other
display (2x) on both launches; its window was moved to the before position with
an Accessibility script (a scratch program, not in the repository). The
Settings window was moved to the top-left (`move 0 100`) before any scenario
that changes a setting, so that it covers no card. The fixtures and their
copies were made by the recipe below into the session scratchpad
(`.../scratchpad/qa-214/`) and opened by absolute path, the same paths on both
builds. A card was opened with `TARMAC_TERM_ID=<boot terminal> tarmac open`.
Board zoom is named where it matters: boards were zoomed out (0.15 to 0.5) so
that cards stay in the window, and set to 1 where a scenario says so.

**Conditions.** The dev window is visible and the screen is unlocked. The card
is not resized. The Document font family in Settings is the default:
`#shim` is the length of `--tarmac-prose-font`, 51 only for the default stack.
Every fixture is taller than the card body, so `scroll.total` is never floored at
the frame height.

**The unit `u`, measured** (`html-card-font-variables-plain.html`, total / 1000;
the reveal copy is the same file with `<meta name="tarmac-zoom" content="reveal">`
after the charset line):

| Page | board zoom | `scroll.total` before / after | `scroll.visible` before / after | `u` |
| --- | --- | --- | --- | --- |
| plain, magnify | 1, 0.5, 0.3 | 3000 at each / 3000 at each | 840 / 840 | **3** |
| plain, reveal | 1 | 1000 / 1000 | 280 / 280 | **1** |
| plain, reveal | 0.3 | 1000 / 1000 | 84 / 84 | 1 |

So the magnify numbers below are the spec's numbers times 3, the reveal ones
times 1.

## What it uses

- [`html-card-standards-mode.html`](html-card-standards-mode.html): blocks whose
  heights make `scroll.total` a function of the mode. `#base` 1000 (both),
  `#mode` 500 in standards mode and 0 in quirks, `#cell` 10 x the font size of a
  table cell (live, every 100 ms: 140 at size 14, 200 at size 20 in standards
  mode; 160 in quirks), `#shim` 51, `#scheme` 7, `#bare` 0 in standards mode and
  30 in quirks. Standards 1698 at size 14 and 1758 at size 20; quirks 1248. Times
  `u`.
- [`html-card-standards-mode-shell.html`](html-card-standards-mode-shell.html):
  the page of S34, a self-scrolling body.
- Copies, made by shell from the fixture (one change of bytes each). The run
  used this recipe with `d` in the scratchpad; the bytes were checked
  (`xxd | head -1`: `bom` starts `ef bb bf 3c 21 64`, `comment` starts
  `<!-- a note -->`, `nodt`, `nodt-reveal` and `shell-nodt` start with
  `<meta charset`, `legacy` with `<!DOCTYPE HTML PUBLIC`). One more copy, not in
  the recipe, for the reveal row of S34: `shell-reveal.html` = the shell page
  with the reveal meta after line 2 (same `awk`).

  ```sh
  f=qa/html-card-standards-mode.html; d=.dev/qa-214; mkdir -p $d
  tail -n +2 $f > $d/nodt.html
  { echo '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">'; tail -n +2 $f; } > $d/legacy.html
  { printf '\xef\xbb\xbf'; cat $f; } > $d/bom.html
  { echo '<!-- a note -->'; cat $f; } > $d/comment.html
  awk 'NR == 2 { print; print "<meta name=\"tarmac-zoom\" content=\"reveal\">"; next } 1' $f > $d/reveal.html
  tail -n +2 $d/reveal.html > $d/nodt-reveal.html
  s=qa/html-card-standards-mode-shell.html
  tail -n +2 $s > $d/shell-nodt.html
  ```

- `tarmac dev snapshot`: `cards[].scroll.{offset, visible, total, shown, thumb}`.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift)
  (`size 1 <n>`, `pick`, `theme`, `wheel`, `move`) and
  [`scripts/qa/wheel-gesture.swift`](../scripts/qa/wheel-gesture.swift), both
  compiled once with `swiftc` into the scratchpad (same source, so the run does
  not pay a compile on each call).
- Region captures with `screencapture -x -R` (a region only; no cursor). The
  before and after captures of the plain page are the same global region.

## Scenarios

`Expected` is the spec's number. `Before` is what the **before build** read in
this run (the spec's standalone-probe value is in brackets where it differs or
is the only one). `Observed` is the after build. Times are from `date`-style
clocks in the driver script (`time.time()`), polled with `tarmac dev snapshot
--timeout 0` every 20 to 50 ms, so they have that resolution.

| # | Card | Expected | Before (live) | Observed (after) | Result |
| --- | --- | --- | --- | --- | --- |
| S23 | the fixture, magnify, size 14 | `scroll.total` 5094 (1698 x u), `visible` 840, shown | 3744, 840 | **5094**, `visible` 840, `offset` 0; the same on 2 reads 3 s apart. (`shown` is the thumb flag: false at rest; `scroll` is an object, thumb {h 22, w 5} at zoom 0.5.) | pass |
| S24 | `nodt` and `legacy` copies, magnify | 3744 (1248 x u) for both | 3744, 3744 | **3744, 3744** | pass |
| S25 | `bom` and `comment` copies, size 14 | 5094 for both | `comment` 3744; `bom` 3793 at size 14; `bom` 3813 after a live change to 20 (the spec's 3813 is a load value) | `bom` **5094**, `comment` **5094** | pass |
| S26 | the fixture and `nodt`, size 14 then 20 then 14 | fixture 5274 within 3 s, no reload, offset kept; `nodt` stays 3744 with no new report; back to 5094 | both 3744 at 20, on 12 polls over 6 s; at 14 again 3744 (8 polls) | Zoom 0.15, fixture scrolled to `offset` 4000. 14 to 20: first poll **0.244 s** after the start of the `settings-window size 1 20` command (the command itself takes 0.239 s; 0.005 s after it returned): fixture **5274**, `offset` 4000, thumb moved; stable on 98 polls over 3 s. `nodt` **3744**, `offset` 0, on the same 98 polls. 20 to 14: first poll 0.240 s after the start (command 0.235 s): **5094**, `offset` 4000. No reload (the offset is the witness). The first poll after the command already read the new total, so the time to the new total is **at most 0.24 s from the start of the command**, not a measured rise. | pass (the new-report clause for `nodt`: only its total was observed, not the message) |
| S27 | `reveal` and `nodt-reveal`, board zoom 1 | `reveal` total 1698, `visible` 280; `nodt-reveal` 1248, `visible` 280 | `reveal` 1248, 280; `nodt-reveal` 1248, 280 | `reveal` **1698**, `visible` **280**; `nodt-reveal` **1248**, **280**. At zoom 0.3 `visible` is 84 on all three reveal cards (it follows the zoom; the totals are the same). | pass |
| S28 | `qa/wheel-travel-probe.html`, gestures of `scroll-indicator-qa.md` S16 | top (0, 840, 48720), one gesture offset 300, end (47880, 840, 48720); probe paints `compat CSS1Compat`. `native-wheel-qa.md` S7 and S13, `scroll-thumb-drag-qa.md` S15 give their recorded numbers | top (0, 840, 48720); the probe painted `compat BackCompat` (a capture) | S16: top snapshot (0, 840, 48720), the probe paints scrollY 0, innerHeight 840, scrollHeight 48720, **`compat CSS1Compat`**. After 10 x `--dy -10`: snapshot offset 300; the probe paints scrollY **300**, `compat CSS1Compat`. At the end (`--dy -1000 --events 25`): snapshot 47880; the probe paints scrollY **47880**, scrollHeight 48720. S7 (10 x `--dy -10`, from 0, each zoom): zoom 0.25 **+1200**, 0.5 **+600**, 1 **+300**, 1.728 **+174**, 2 **+150**, 3 **+100**. S13 (zoom 1, scrolled to 7200 with `--dy -100 --events 24`, the aim over `#inner`): `inner` 0 to **100**, scrollY **7200** before and after (the probe's `target` line was cut off in the capture, not read). S15, the probe's row (zoom 1, thumb dragged from the top by 121 pt, then from the top by 300 pt): offset **23940**, then **47880** (total 48720, visible 840). Not run: the S15 clauses "no drag" and "a drag of 1"; S7 and S13 on the before build. | pass for what was run |
| S29 | `html-card-scheme/p0`, `p1`, `p2`, `p7`, `p8`, `p9`, dark theme, then light | the colours of `theme-qa.md` S62 and S66; every console line ends `matches=true` | not run on the before build (the spec says it passes before) | Zoom 0.15, modal colours of the card body in a region capture (canvas, then the block's border colour), `total` 876 on all six. Dark, as loaded: P0 `1e1e1e` / `ffffff`; P1 `1e1e1e` / `ffffff`; P2 `ffffff` / `000000`; P7 `1e1e1e` / `ffffff`; P8 `1e1e1e` / `222222`; P9 `ffffff` / `ffffff` (one colour, the block is invisible). After a live change to light (Settings, Theme, Light; `theme.in_effect` light): P0, P1, P2 `ffffff` / `000000`; P7 `1e1e1e` / `ffffff`; P8 `ffffff` / `222222`; P9 `ffffff` / `000000`. Theme set back to Dark. **The console lines (`matches=true`) were not read**: no console was opened. | pass for the colours; console clause not run |
| S30 | the three `html-card-font-variables*` fixtures; `html-card-font-variables-qa.md` S30 to S40 again | every expected value of that record holds; S37 compared on the build before and after | the plain page: total 3000, frame 392 x 310, `visible` 840, a region capture (see below) | S30 to S40 re-run on this build: every value holds. They are recorded in `html-card-font-variables-qa.md`, section "2026-10-10, re-run on the standards-mode build". The plain page against the before build: total 3000 and 3000, frame {636, 80, 392 x 310} and the same, `screen_rect` {711, 254, 196 x 155} and the same, region capture **byte-identical** (`cmp`; 0 differing pixels of 30380). | pass |
| S31 | `sandbox-probe.html`, `scroll-band-probe.html`, `doc-prose-scaler-promotion-probe.html` | each passes its own check (`html-card-qa.md` S18; `scroll-band-qa.md` row 1; `doc-card-raster-cost-qa.md`); totals recorded | totals 1966, 30889, 6416 (the probe's: the same) | totals **1922, 31487, 6421**. `sandbox-probe`: the page paints `VERDICT: LEAKY (1/11 escapes)` on both builds; the one escape is `navigator.sendBeacon` (`escaped` is `ok === true`, and the page says the return value alone does not confirm delivery). The out-of-band listener the page asks for (`python3 -m http.server 8737 --bind 127.0.0.1`, started and stopped by pid by me) saw **no request** while the card was reloaded (visible 840, 280, 840 on the card's own reload), after build only. `scroll-band-probe`: loads, the page is the article; its check (`relay msgs`, `allInteger`) listens for the wheel relay that spec 2610.0002 removed, and that record says it is closed: **not run**. `doc-prose-scaler-promotion-probe`: the check reads the composited layers in WebKit Inspector: **not run**. | totals pass; sandbox: no request seen; the other two checks not run |
| S32 | the fixture, "Show scroll bars: Always" | no track and no gutter at the right edge of a region capture; `scroll` not `null`; total 5094 | not run | The app was ended (pid 91448, by `kill`), `defaults write TarmacApp AppleShowScrollBars -string Always` (the unbundled binary's own domain; the global domain was not touched), `make run` again (pid 50437). Positive control, a page that sets `documentElement.style.scrollbarWidth = "auto"` after the shim and paints its `clientWidth` as a block (`scrollbar-control.html`, made for this run): `total` 6477 = (1000 + 1159) x 3, so the root scroller takes 17 px; at zoom 1 its card's last columns read `2f81f7 x15, ffffff x4, 474e55` (a 4-pixel white gutter, then the card border). The fixture, same capture: the 19 columns before the border are all `2f81f7`, the page's own block. `scroll` an object, `total` **5094**, `visible` 840. The default was deleted afterwards (`defaults read TarmacApp`: domain does not exist; the global key is absent). | pass |
| S33 | `make qa` | passes | not run | `make qa DEV_DIR=<this channel>`, run **first**, on the fresh after channel, before the Settings window was ever opened (a second window makes `tarmac dev key` lose ctrl chords, see the dev-channel skill): **27/27 checks passed**, S21 skipped (it needs another app in front), 17 s. This is a change of the spec's order, made on purpose. | pass |
| S34 | `html-card-standards-mode-shell.html` and its `nodt` copy, magnify, after 1 s | doctype copy `{offset 0, visible 840, total 840, shown false}`, no thumb; `nodt` copy `scroll` `null`. Reveal doctype copy (0, 280, 280) | `scroll` **`null`** for the shell, `shell-nodt` and `shell-reveal`, on every read over about 20 s | The shell copy: `{offset 0, visible 840, total 840, shown false, thumb null}`. `shell-nodt`: `scroll` **`null`** on 6 reads over 3 s. `shell-reveal` at zoom 1: (0, 280, 280), thumb `null`. At zoom 0.3 the shell is (840, 840) and the reveal one (84, 84). | pass |

## Open questions the run settles

- **U1. The live app gives the probe's numbers.** Yes, for every number the spec
  states: S23 5094; S24 3744; S25 5094, and before 3744 and 3793 (3813 at a
  live change to 20); S26 5274 and back to 5094; S27 1698 and 1248; S31 1922,
  31487, 6421 (before 1966, 30889, 6416); S34 (0, 840, 840) and `null`; the
  plain page 3000 in both. The one number that is not the probe's is the time:
  the probe read the new total 0.065 s after the `fonts` message, the live app
  gave the new total at the first poll, at most 0.244 s after the start of a
  command that itself takes 0.24 s.
- **U2. Pixels of an unchanged page.** The plain page, region capture of the
  card (global 1441,475, 196 x 155, zoom 0.5, default settings): before build
  against after build, 0 differing pixels, bytes equal. Two captures of one
  build 1 s apart: 0. The page is a flat `rgb(1, 2, 3)` with no text, so the
  capture is sensitive to the header and the frame, not to the layout of the
  page. The after-build captures at size 20 with Document Georgia: 0 differing
  pixels against the default. With Interface Menlo: 428 differing pixels, all
  in x 22-186, y 5-10 (the card header's label). After the Settings values
  were back at default: 0. A capture taken after `make qa` on the same board
  differs by 4825 pixels in x 0-55, because `make qa` left the boot terminal at
  600 x 400, and it overlaps the left 22 points of the plain card; the
  comparison above is the one taken before `make qa`.
- **No flash on first open.** `screencapture -x -R1601,392,229,310` (the
  visible part of the first card on a fresh board) in a loop of 60 frames, 70 ms
  apart, started 0.6 s before `tarmac open` of `flash-probe.html` (a page for
  this run: a paragraph and a table cell set with
  `var(--tarmac-prose-font, Courier)` and `var(--tarmac-prose-size, 11px)`, and
  a script that paints `document.compatMode`). Defaults: 9 frames of an empty
  board, 1 frame (0.034 s after the open call) of the card chrome with an empty
  dark body, then 50 identical frames of the page, from 0.114 s: system font
  at 14 px, the cell at 14 px, `mode CSS1Compat`. Document Georgia at 24
  (a second fresh board): 8, 1, then 51 identical frames, in Georgia at 24 px,
  `mode CSS1Compat`. No frame shows Courier, 11 px, or a quirks layout. How
  sure: a single frame of 16 ms between two captures 70 ms apart could be
  missed.
- **U3.** The mode of a very large file: **not run.**
- **U4.** Pages that already worked around quirks mode: **not run** (they are
  the user's pages).
- **U5. A self-scrolling page in the real app.** `scroll` is an object with
  `shown` false and `thumb` null, `offset` 0, `visible` 840, `total` 840 (S34).
  No guard in the app turns it into `null`.

## Found during the run

- **A family change while a card is culled is not seen in the timer-driven
  blocks.** Fixture `html-card-font-variables.html` (the #225 fixture, whose
  prose and mono blocks follow the family with a 100 ms timer), panned off the
  window until `focus` answered `card_hidden` (`screen_rect.y` -3233; at
  -673 `focus` was still accepted and borrowed the card; at -1313 the reply
  was an error object that was not read in full), Document size 14 to
  20 while culled: `total` 6444 on the first poll (0.37 s). Document family
  Georgia while culled: `total` stayed **6444** on 15 polls over 5.7 s (the
  new family would add 33, 6477), and at `zoom 0.15` (the card still above the
  window at `screen_rect.y` -1448, `focus` still `card_hidden`) 4 more polls
  over 2.3 s: 6444. After the board was panned back until the card was in the
  window again: 6477, stable on the next 4 reads. So the size reaches a culled
  card (it is CSS only) and the family does not until the card is back; whether
  the message arrives while culled or after was not told apart. The same
  mechanism is in the before build; this run did not repeat it there.
- **Pre-existing, same on both builds:** the sandbox probe reads `LEAKY (1/11
  escapes)` (sendBeacon).
- **`make qa` changes the board.** Its resize scenarios leave the boot terminal
  at 600 x 400 (D4/D5), and its fixtures stay as cards.
- **The after app opens on the 2x display** (the window at x 2910), the before
  app on the 1x display (x 730). The captures needed the same display, so the
  window was moved.
- **The first S26 on the before build was run with the Settings window over
  the cards** (it opens at x 847, y 250). It read 3744 throughout, as expected
  in quirks mode. It was run again with the window moved away: the same.
- **`settings-window.swift pick 2 "System Default"`** answered "row 2 lists 0
  entries" once, straight after a `pick 1`; the Document family stayed Georgia
  until the call was repeated. A repeat 1 s later worked.
- **The default theme is Dark** (`ThemeChoice.standard`), and the system
  appearance of this Mac is Light: the choice Auto resolves to light here.

## Left as it was

Settings back at Document 14, Terminal 16, both families System Default, theme
Dark; `defaults` key removed; the dev app ended by `kill` of the pid that
`lsof -t <dev socket>` gave; the daemon by `make kill-daemon`; the dev
directory removed. The installed Tarmac (pid 62812, 62815) was not touched.
