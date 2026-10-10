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

