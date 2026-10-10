# QA — HTML card font variables (#225, spec 2610.0010)

The live half of [spec 2610.0010](../.blueprint/specs/2610.0010_html_card_font_variables.md):
its `[QA]` scenarios, with the values observed. The unit scenarios are
`CardFontVariablesTests`, `CardHostMessageTests`, `HTMLCardSessionTests` and
`CardShimTests`.

It is also the §1.3 exception-1 and exception-2 discharge for the shell the
change adds or touches: `Theme.cardFonts`, `HTMLCardView.fontsChanged` and
`CardSchemeHandler.webView(_:start:)`.

**Run:** 2026-10-09, macOS 26.7 (25G229), a `make run DEV_DIR=.dev/qa-225` debug
build (pid 18536) of the branch `feat/225-html-card-font-variables` on its base
`ff49575` plus the **uncommitted working tree** (the implementation, the spec and
these files). The window (1100 x 732) was on a 2560 x 1440 display at 1x
(a 196 x 155 point card region captures as 196 x 155 pixels), visible, the screen
unlocked (`CGSSessionScreenIsLocked` absent). The channel started with no state:
`board-0` with its boot terminal, Terminal 16, Document 14, both families System
Default. The Settings window stayed open for the whole run, moved to the top-left
(`move 0 100`) so that it did not cover a card. Board zoom is named in each row;
the boards were zoomed out (0.15 to 0.5) so that the card stayed in the window,
and back to 1 where the scenario needs 1.

**The unit `u`, measured** (the plain page, total / 1000):

| Page | board zoom | `scroll.total` | `scroll.visible` | `u` |
| --- | --- | --- | --- | --- |
| plain, magnify | 1, 0.5, 0.3 | 3000 at each | 840 | **3** |
| plain, reveal | 1 | 1000 | 280 | **1** |

So the magnify expectations below are the spec's numbers times 3: `T14` =
(1400 + 51 + 23 + 74) x 3 = 4644; 600 x u = 1800; the family steps are 11 x 3 = 33 and
9 x 3 = 27. The reveal ones are times 1.

## What it uses

- [`html-card-font-variables.html`](html-card-font-variables.html): four
  blocks. `scroll.total` is the sum of their heights: the size block
  (`calc(var(--tarmac-prose-size, 14px) * 100)`), the prose block and the mono
  block (the length of the font value, in px, read every 100 ms), and the load
  block (the sum of the two lengths, read once while the page is parsed). With
  nothing chosen the two lengths are 51 and 23.
- [`html-card-font-variables-plain.html`](html-card-font-variables-plain.html):
  `<html style="background: rgb(1, 2, 3)">` and a block of 1000 px, no
  variable. It gives the unit `u` of `scroll.total` for each zoom mode, and it
  is the page of S37.
- [`html-card-font-variables-cascade.html`](html-card-font-variables-cascade.html):
  the page of S40. A copy with `<script>document.documentElement.setAttribute("data-x", "")</script>`
  appended sets `data-x` on `<html>`.
- A reveal copy of each page: add `<meta name="tarmac-zoom" content="reveal">`
  after the `<meta charset>`.
- `tarmac dev snapshot`: `cards[].scroll.total`, `scroll.offset`,
  `scroll.visible`, `scroll.thumb`, `board_rect`, `fonts`.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift)
  (`size 1 <n>`, `pick 2 <family>`, `pick 1 <family>`).

**Conditions.** The dev window is visible and the screen is unlocked. The card
is not resized. A scroll offset that is kept is the witness that the document
was not reloaded.

## Checks

| Scenario | Observed | Result |
| --- | --- | --- |
| **S30** Load, size 14 | Plain page first (above). Fixture opened with `tarmac open` from the boot terminal, zoom 0.5 and 0.3: `scroll.total` **4644**, `visible` 840, `offset` 0. Expected (1400 + 51 + 23 + 74) x 3 = 4644. With nothing from the load block (74 absent) it would read 4422. | pass |
| **S31** Size 14 to 20, offset kept | Zoom 0.3. Scrolled with `wheel-gesture.swift --select --dy -20 --events 10`: `offset` 2000, `total` 4644, `thumb` {h 14, w 3, x 1046, y 131}. Size 20 by `settings-window.swift size 1 20`: first read 0.93 s after the command, `total` **6444** (= 4644 + 1800), `offset` **2000**, `thumb` {h 10, w 3, x 1046, y 122}. Stable for the 13 s that were polled (30 reads). Back to 14: `total` 4644, `offset` 2000, thumb as before. | pass |
| **S32** Document family | Offset 2000, size 14. Georgia: `fonts.document.css` `"Georgia", -apple-system, ...`, `total` 4644 -> **4677** (+33 = 11 x 3). System Default: **4644**. | pass |
| **S33** Interface family | Menlo: `fonts.interface` `{face: Menlo-Regular, saved: Menlo}`, `total` 4644 -> **4671** (+27 = 9 x 3). System Default: **4644**. | pass |
| **S34** Culled card | Offset 2000, size 14, `total` 4644. The board was panned with `settings-window.swift wheel 1230 721 -40` three times (the point is empty board, and the window at it was the dev pid 18536): the card `screen_rect.y` -873, and `tarmac dev focus <path>` answered `card_hidden`. Size 20 while culled: `total` **6444** after 3 s, `offset` 2000 (the card already reported the new total while it was culled). `zoom 0.15`: `total` 6444, `offset` 2000 on six reads over 3 s. At 0.15 the card was still at `screen_rect.y` -268 (above the window), yet `focus` on it was accepted (it borrowed the card; `key <term> escape` undid it): the app's cull margin is wider than the window. | pass (see Found) |
| **S35** Second board | Size 14. `board-0` mounted; ⌘K, ⌘N made `board-1` (zoom 1, then 0.5); a copy (`fixture-board2.html`) opened there: `total` 4644. ⌘K, ⌘1 back to `board-0` (`board_id` read). Size 20 on `board-0`. ⌘K, ⌘2: `board-1` mounted, the copy read **6444**, `offset` 0, `visible` 840, on three reads over 2 s. | pass |
| **S36** Request-time values; the Terminal size is not sent (a guard: it passes before the change) | Size 20, a new path (`s36.html`, a copy never opened before), `board-0` zoom 0.15. Polled every ~0.1 s from before the open: `null`, then **6444** (0.21 s later; never any other value). Size 16 (live: 5244), then the file touched: the card went `visible` 42 (loading) -> 840 with `total` **5244** (not 6444). Georgia (live: 5277, +33), then touched: first **5277**, then **5310** (+66 = 22 x 3 against 5244). Terminal size 16 -> 16.5 -> 18 -> 16: `total` 5310 at each, read 1.5 s after each. Settings restored afterwards. | pass (last clause: a guard) |
| **S37** The plain page equals `main` at `ff49575` (a guard: it passes before the change) | **The comparison with `main` was not run** (the working tree is uncommitted, so no checkout or stash was made, and no second build was started). What was compared: the page against itself across the settings, and against the spec's arithmetic. Size 14, System Default: `total` 3000 (= 1000 x 3), frame `board_rect` 392 x 310, `visible` 840. Size 20, Document Georgia: the same three numbers. `screencapture -R` of the card (196 x 155 points at zoom 0.5, global 1441,462): the two PNGs are byte-identical (`cmp`), pixel (100,100) and (50,60) read 1,2,3 in both (the page background `rgb(1, 2, 3)` is kept). With Interface Menlo as well, 467 pixels differ, all in x 7-186, y 5-10: the card header's label (the Interface font is the card chrome's, not the page's); with Interface back at System Default, 0 pixels differ. A second capture at the same settings differs by 0 pixels. | pass for the page; main-build comparison not run |
| **S38** Magnify card at board zoom 1, 2, 1 | `board-1`, copy of the fixture, no `tarmac-zoom` meta. Zoom 1, size 14: `board_rect` {636, 80, 392 x 310}, `total` 4644, `visible` 840. Size 20: `board_rect` unchanged, `total` **6444**, `visible` **840**. Zoom 2: `total` 6444, `visible` 840 (`screen_rect` 784 x 620). Zoom 1: `total` 6444, `visible` 840, `screen_rect` as before. | pass |
| **S39** Reveal card | `board-2`, reveal copy of the fixture, board zoom 1 (settled), `u` = 1 from the reveal plain page (total 1000, visible 280 at zoom 1). Size 14: `total` 1548, `visible` 280, `board_rect` {636, 80, 392 x 310}. Size 20: `total` **2148** (+600 x 1), `visible` **280**, `board_rect` unchanged, on two reads 2 s apart. | pass |
| **S40** Cascade | `board-2`, zoom 0.4, `u` = 3. Size 14: cascade page `total` **2730** = (140 + 770) x 3; copy with `data-x` set on `<html>`: **3960** = (550 + 770) x 3. Size 20: **2910** = (200 + 770) x 3 and **3960**, stable on two reads 2 s apart. | pass |

## U2. A flash of the default font on first open

Not seen. `screencapture -x -R 1601,392,229,310` (the visible part of the card
on a fresh board, region only) ran in a loop of 40 frames, started 0.4 s before
`tarmac open` was typed; the mean spacing of the frames was 69 ms. The page
(`u2-probe.html`, two paragraphs set with `var(--tarmac-prose-font, Courier)`
and `var(--tarmac-prose-size, 11px)`, a probe made for this run and not a
fixture of the spec) was opened twice:

- Defaults (SF, 14px). 5 frames of an empty board, 1 frame of the card chrome
  with a dark empty body, then 34 identical frames of the page.
- Document `Georgia` at 24 (set before the open, on a fresh board). The same
  sequence: 5 empty, 1 frame of the chrome with an empty dark body, 34
  identical frames of the page set in Georgia at 24px. No frame shows Courier,
  11px, SF or 14px.

How sure: the first frame that has the page already has the chosen font and
size. A single frame of 16 ms between two captures 70 to 90 ms apart could be
missed, so this is "not seen at this cadence", not a proof. The card body is
dark and empty until the document is shown (`card-host.js`), which is the
reason a flash is not expected. The fixture's load block is the value witness
(S30, S36): its 74 is present from the first script. Only the open after a
setting change was timed; a live change of a card that is already open was
not captured.

## Found during the run

- **`u` is 3 for a magnify card, 1 for a reveal card**, measured on the plain
  page (3000 and 1000). The spec's totals are in `u`, so a magnify total is
  3 x the spec's number (4644, not 1548).
- **S34: a culled card still reports its new total.** With the card refused by
  `focus` (`card_hidden`, `screen_rect.y` -873), the size change to 20 moved
  `total` to 6444 within 3 s, before any zoom. So `zoom 0.15` is not what
  delivered it. At `zoom 0.15` the card was still above the window
  (`screen_rect.y` -268) and `focus` on it succeeded: the cull margin is wider
  than the window. The scenario's result holds either way.
- **Not tested:** a family change while the card is culled (S34 used the
  size). The fixture's 100 ms timer reads the family values, and the spec says
  that a culled card holds timers, so the prose and mono blocks may update only
  after the card is back.
- **A wheel over a card that is not selected pans the board** (`qa/native-wheel-qa.md`): the first `wheel-gesture.swift` call without `--select` moved the
  board 200 points. S31 used `--select`.
- **The card header follows the Interface family**, so a region capture of a
  whole card differs when Interface changes (S37, 467 pixels in the header
  row). The page body did not change.
- **Not done:** the main-build comparison of S37; closing the cards one by one
  (no driver verb closes a card; the channel was discarded whole); the Settings window was not closed.


## 2026-10-10, re-run on the standards-mode build (spec 2610.0011, S30)

The S30 to S40 above, run again on the build of `fix/214-html-card-standards-mode`
(`538508e` plus the uncommitted working tree), where a file with a doctype is in
standards mode. The scenarios are the same; nothing above was changed. The
values are those of the 2026-10-09 run (and so of the spec's arithmetic) with no
change of arithmetic.

**Run:** macOS 26.7 (25G229), `make run DEV_DIR=.dev/qa-214`, pid 91448, window
1100 x 732 on the 2560 x 1440 display at 1x, screen unlocked. Fresh channel, the
Settings window moved to the top-left, board zoom named per row. The fixtures
were copies of the three `html-card-font-variables*` files made with `cp`, opened
by absolute path. `u` = 3 for a magnify card (the plain page, 3000 at zoom 1,
0.5 and 0.3, `visible` 840) and 1 for a reveal card (1000, `visible` 280 at
zoom 1), as on 2026-10-09.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S30** Load, size 14 | Fixture on a fresh board, zoom 0.5 and 0.3: `scroll.total` **4644**, `visible` 840, `offset` 0. | pass |
| **S31** Size 14 to 20, offset kept | Zoom 0.3, `wheel-gesture.swift --select --dy -20 --events 10`: `offset` 2000, `total` 4644, thumb {h 14, w 3, x 759, y 331}. `settings-window size 1 20`: first read 0.35 s after the command started, `total` **6444**, `offset` **2000**, thumb {h 10, w 3, x 759, y 322}; 10 reads 1 s apart: 6444, 2000 on all. Back to 14: 4644, 2000, thumb as before. | pass |
| **S32** Document family | Georgia: `fonts.document.css` `"Georgia", -apple-system, ...`, `total` 4644 to **4677** (+33). System Default: **4644**. | pass |
| **S33** Interface family | Menlo: `fonts.interface` `{face: Menlo-Regular, saved: Menlo}`, `total` 4644 to **4671** (+27). System Default: **4644**. | pass |
| **S34** Culled card | Offset 2000, size 14. Panned with `settings-window wheel 1230 721 -40`, 3 then 2 then 6 times (the window at that point was the dev pid, checked before each with a window-list read). At `screen_rect.y` -673 `focus` still succeeded (it borrowed the card; `key <term> escape` undid it). At -1313 the reply was an error object that was not read in full; at -3233 `focus` answered `card_hidden`. At -3233, size 20: `total` **6444** on the first read (0.37 s), `offset` 2000, and on 6 reads over 4 s. `zoom 0.15`: 6444, 2000 on 4 reads over 2.3 s (the card was at `screen_rect.y` -1448, `card_hidden`). **Family change while culled** (this run, size 20): Georgia, `total` **6444** on 15 reads over 5.7 s, where the new family adds 33 (6477); at zoom 0.15, still culled, 6444 on 4 reads over 2.3 s; after the board was panned back until the card was in the window: **6477**, 4 reads. So a size reaches a culled card and a family does not reach the timer-driven blocks until the card is back (not told apart: whether the `fonts` message arrives later or the 100 ms timer is held while culled). Georgia set back to System Default and size to 14 afterwards. | pass (size); family: see Found |
| **S35** Second board | Size 14. `board-5` mounted with the fixture; ⌘K, ⌘N made `board-6` (zoom 1, then 0.5); a copy (`fixture-board2.html`) opened there: `total` 4644. ⌘K, ⌘5 and ⌘6 (the palette numbers are list positions, not board numbers; `board_id` was read each time). Size 20 set while another board was mounted. ⌘K, ⌘7: `board-6` mounted, the copy read **6444**, `offset` 0, `visible` 840, on 4 reads over 2 s (the first one 0.3 s after the key). | pass |
| **S36** Request-time values; the Terminal size is not sent (a guard) | Size 20, a new path (`s36.html`, a copy never opened before), polled every ~0.05 s from 0.6 s before the open: `null`, then **6444** at 0.65 s, never another value. Size 16 (live: 5244), file touched: 5244 (`visible` 140 for 0.06 s while it reloaded, then 840), not 6444. Georgia (live: 5277), touched: **5310** at 0.54 s (+66 = 22 x 3 against 5244). Terminal size 16 to 16.5 to 18 to 16: `total` 5310 at each, read 1.5 s after each. Settings restored afterwards. | pass |
| **S37** The plain page equals `main` at `ff49575` (the base of the work) and the build before this change (`538508e`) | **Compared against the build before the change this time** (`538508e`, a second app, run earlier the same day, same window position, same channel recipe, same copy of the file at the same path). Size 14, System Default, zoom 0.5: `total` **3000** and **3000**, frame `board_rect` {636, 80, 392 x 310} and the same, `screen_rect` {711, 254, 196 x 155} and the same, `visible` 840 and 840. Region capture (`screencapture -x -R1441,475,196,155`, global): 30380 pixels, **0 differ**, the two PNGs are byte-identical (`cmp`); pixel (100,100) and (50,60) read 1,2,3 in both. A second capture of each build 1 s later: 0 differ. On the after build at size 20 with Document Georgia: total, frame and capture identical to the default (0 pixels). With Interface Menlo as well: 428 pixels differ, all in x 22-186, y 5-10 (the card header's label). Interface and Document back at System Default, size 14: 0 pixels. The page is a flat `rgb(1, 2, 3)` with no text; the capture sees the header and the frame. | pass (also against the before build) |
| **S38** Magnify card at board zoom 1, 2, 1 | `board-7`, copy of the fixture, no `tarmac-zoom` meta. Zoom 1, size 14: `board_rect` {636, 80, 392 x 310}, `total` 4644, `visible` 840. Size 20: `board_rect` unchanged, `total` **6444**, `visible` **840**. Zoom 2: 6444, 840 (`screen_rect` width 784). Zoom 1: 6444, 840, `screen_rect` width 392. Again 2 s later: the same. | pass |
| **S39** Reveal card | `board-7`, reveal copy (`<meta name="tarmac-zoom" content="reveal">` after the charset line), zoom 1, `u` = 1. Size 14: `total` 1548, `visible` 280, `board_rect` {1114, 80, 392 x 310}. Size 20: `total` **2148** (+600), `visible` **280**, `board_rect` unchanged, on two reads 2 s apart. | pass |
| **S40** Cascade | `board-7`, zoom 0.4, `u` = 3. Cards opened at size 20: cascade page `total` **2910** = (200 + 770) x 3; the copy with `data-x` set on `<html>`: **3960** = (550 + 770) x 3. Size 14: **2730** = (140 + 770) x 3 and **3960**. Size 20 again: **2910** and **3960**, stable on two reads 2 s apart. | pass |

### Found

- **A family change while a card is culled is not seen in the timer-driven
  blocks** (S34, this run). This is the "Not tested" item of the 2026-10-09
  run: the size reaches a culled card, the family does not until it is back in
  the window. Same code in the build before this change; not repeated there.
- **S37 was compared against the build before the change** this time: the plain
  page is byte-equal in total, frame and capture (30380 pixels, 0 differ).
- **`u`**: 3 (magnify) and 1 (reveal), as before.
- **A focus at a card that is far off screen can still be accepted.** At
  `screen_rect.y` -673 (zoom 0.3) `focus` succeeded and borrowed the card; at
  -3233 it answered `card_hidden`.
- Interface Menlo changes the card header (428 pixels at x 22-186, y 5-10), not
  the page, as on 2026-10-09.
