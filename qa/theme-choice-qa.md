# QA — the theme choice (#217, spec 2610.0008)

**This file holds two runs.** The current run is
[the run of revision 2](#the-run-of-revision-2-2026-10-07), at the end of
this file: 31 `[QA]` scenarios, S33 to S56 and S65 to S71, on the list and
the showcase. The text from here to that heading is the run of revision 1
(2026-10-06, the two pop-ups). It is kept as that run's record and its
observed values are not changed. Revision 2 replaced the pane that it
describes, so its rows are not the state of the code.

The live half of [spec 2610.0008](../.blueprint/specs/2610.0008_theme_choice.md):
its 24 `[QA]` scenarios, S33 to S56, with the values observed. The unit
scenarios are `ThemeCatalogTests`, `ThemeChoiceTests`, `PaletteTests`,
`PaletteCheckTests`, `AppPrefsTests`, `ThemeCSSTests`, `PageThemeTests` and
`DevSnapshotTests`.

It is also the live check for the shell of this change: `ThemeSettings`,
`Theme`, `ThemePane`, `ThemeTile`, the guards of `DocWebView` and
`HTMLCardView`, and `DevSnapshotReader`.

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.
The method is the one of [`theme-qa.md`](theme-qa.md).

**Result:** 23 scenarios pass. None fails. 1 was not run: S49, which needs
the Mac's appearance changed and is left to the user. No code was changed in
this run. Five rows pass with a limit that the row gives. S33 and S52: the
values for `f683657` are from the earlier record, not from a build of that
commit. S55: the Mac was Light for both halves. S41 and S42: no frame holds
a Breeze Dark fill, which is the test those scenarios name; but a doc card's
page is the system's dark canvas for 6 frames (S41) or 1 frame (S42) before
it is the theme's page, and it is the same under Breeze Dark.

**Run:** 2026-10-06, macOS 26.7 (25G229), a `make run` debug build of the
branch `feat/217-choose-light-dark-theme`: the commit `f683657` and the
working tree on it, which was not committed. One build served the whole run.
Main display: BenQ EW2770QZ at 1×, with its own colour profile
(`BenQ EW2770QZ`). The two windows of the dev app were on it for the whole
run. A second display (the built-in panel, at 2×) was connected and was not
used. The Mac's appearance was Light and was not changed. A fresh dev
channel, `.dev/qa217`, removed after the run.

There were five launches on that channel:

| Launch | State at the start | Scenarios |
| --- | --- | --- |
| A | fresh channel | S52 only. The app and its daemon were then stopped and the channel was made empty. |
| B | fresh channel | S34, S33, S53, then the board, then S35 to S46, S54, S55, S56 |
| C | the files of B, the same daemon | S47, S51 |
| D | a prepared `app-prefs.json`, the same daemon | S48 |
| E | a prepared `app-prefs.json`, the same daemon | S50 |

## The capture tolerance

The tolerance is 1 for each channel: the value that `theme-qa.md` measured
on a tree before the theme changes. It was checked again in this run, on
this tree, with Breeze Dark. This change must not change the values of
Breeze Dark, so they are a known input.

| Fill | Value | Sampled, 3 or 4 points each |
| --- | --- | --- |
| board | `24282c` | `24282c` |
| doc card header | `353b41` | `353b41` |
| terminal body | `31363b` | `31363b` |
| status bar | `2b3036` | `2b3036` |
| doc page | `2b3036` | `2b3036` |

The largest difference in a channel is 0, at 16 points. Each 7 × 7 square
round a point held one colour. No sampled value in this record that is held
to a token is more than 1 from it.

The file that `screencapture` writes is tagged `sRGB IEC61966-2.1`, and its
bytes are read as they are. A pass of `sips --matchTo` with the sRGB profile
changed 0 of the 2 287 500 pixels of one capture, so the two ways of reading
give the same values.

## What it uses

- `tarmac dev snapshot`: `theme`, `fonts`, `board_id`, `viewport`,
  `content_origin`, and each card's `screen_rect`, `scroll` and `term`.
- A capture is `screencapture -o -l <window id>` of a window of the app's
  pid. A sample point is computed from `content_origin` and a card's
  `screen_rect`. The scale is 1, so a point is a pixel. An open menu is
  captured by region (`screencapture -R`).
- The main window was made 1830 × 1250 through Accessibility. The Settings
  window was moved beside it.
- [`theme-doc.md`](theme-doc.md), scrolled to its middle. A scratch page as
  P0 of [`html-card-scheme/`](html-card-scheme/README.md), which states no
  colour scheme and no colour, with one console line of each level. Scratch
  docs, and one doc in each of two throwaway repositories.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift):
  `open`, `rows`, `pane`, `theme`, `theme-of`, `pick`, `size`, `step`,
  `move`, `menu`. *Note of 2026-10-07:* the verb `theme-of` is the script
  of revision 1. Revision 2 removed it. The script of today has `show` and
  `apply` in its place (see the run of revision 2).
- [`scripts/qa/wheel-gesture.swift`](../scripts/qa/wheel-gesture.swift)
  scrolls a selected card.
- A press and a drag are posted at the HID tap: to move a card by its
  header, to open a console, and to select empty cells of a terminal.
- A scratch tool opens a pop-up through Accessibility, captures the region
  round it while its menu is open, and then chooses the item the pop-up
  already had.
- A scratch script in a terminal card sends the colour queries and logs the
  answers.
- A recording is 60 fps `ffmpeg` of the screen device `Capture screen 0`. Its
  colours are not sRGB values. The values of the Breeze Dark fills in a
  recording were read first: board `202327`, header `2e3339`, terminal body
  `2b2f33`, status bar and doc page `262a2f`. A recording is searched for
  those values, with a tolerance of 1.

*Five* in a row means the five fills in the spec's order: board, doc card
header, terminal body, status bar, doc page. The header is sampled on a doc
card and the terminal body on the prime terminal. The board is sampled 100
points or more from a card (see *Found on the way*).

## Checks

### The window

| Scenario | Observed | Result |
| --- | --- | --- |
| **S33** The pane | Fresh channel, ⌘,, `pane Theme`. Labels of the pane, in order: *Appearance*, *Light theme*, *Dark theme*. `rows`: tiles *Auto* 0, *Light* 0, *Dark* 1; `0 selected=Breeze Light`, `1 selected=Breeze Dark`. `theme-of Light "Breeze Light"` prints `lists ["Breeze Light", "Catppuccin Latte", "GitHub Light", "Solarized Light"]`. `theme-of Dark "Breeze Dark"` prints `lists ["Breeze Dark", "Catppuccin Mocha", "GitHub Dark", "Solarized Dark"]`. Frame 691 × 299 on *Fonts*, on *Theme*, on *Fonts* again and on *Theme* again. The two pop-ups have one frame size, 164 × 26, and one left edge. **The frame on `f683657`:** that commit was not built in this run. `theme-qa.md` (S27) has 691 × 299 for #209, and `f683657` is the merge of #209. So the two frames are equal by that record: the three rows fit. | pass (the `f683657` frame is from the earlier record) |
| **S34** A fresh channel | First snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`. The channel's directory holds the two sockets, `state.json` and `tarmacd.log`, and no `app-prefs.json`. Five: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. | pass |

### A choice

The board of launch B, made under Breeze Dark: the prime terminal with the
lines of S37, `theme-doc.md` at 392 × 500 with `scroll.offset` 690, the
scratch P0 page with its console open, a second terminal with 300 lines of
scrollback, two docs of two repositories, and far to the right two
terminals, a doc and a P0 page that are culled at zoom 1. A second board
with a terminal and a doc was made later, for S36 and S42.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S35** Breeze Dark to Catppuccin Mocha | `theme-of Dark "Catppuccin Mocha"`, no restart. Snapshot: `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}`. File: `{"warn_before_quit":true,"theme_dark":"catppuccin-mocha"}`. Five: `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. `rows`: `1 selected=Catppuccin Mocha`, and `0 selected=Breeze Light`. A capture done 0.46 s after the harness came back still had the five of Breeze Dark; the next one had the values above. See *Found on the way*: the fills change 0.25 s after the item is pressed. | pass |
| **S36** Each part | The table below. No capture of the main window under Mocha holds a 4 × 4 flat area of a fill that only Breeze Dark has (12 captures scanned for the eight values, tolerance 0). | pass |
| **S37** Text already drawn | No key in the terminal after the choice. Full block `cdd6f4` (it was `ced2d6`). ANSI 2 background `a6e3a1`. The sixteen backgrounds, 0 to 15: `45475a` `f38ba8` `a6e3a1` `f9e2af` `89b4fa` `f5c2e7` `94e2d5` `bac2de` `585b70` `f7aec2` `c2ecbf` `fcd682` `aeccfc` `f398da` `b1eae1` `a6adc8`: the spec's table. Body `1e1e2e`. Selected empty cell `415960`; `1e1e2e` with `94e2d5` at 0.3 computes `415960`. Grid 44 × 14 before and after. | pass |
| **S38** The answers | Mocha: `rgb:cdcd/d6d6/f4f4`, `rgb:1e1e/1e1e/2e2e`, `rgb:f5f5/e0e0/dcdc`, `rgb:a6a6/e3e3/a1a1`, `CSI ? 997 ; 1 n`. *Light* with Solarized Light: `rgb:6565/7b7b/8383`, `rgb:fdfd/f6f6/e3e3`, `rgb:6565/7b7b/8383`, `rgb:8585/9999/0000`, `CSI ? 997 ; 2 n`. Each answer came with the `ST` end. | pass |
| **S39** A doc keeps its place | Page `181825` (it was `2b3036`). Code block `1e1e2e`. The fullest pixel of the heading *The parts* is `cdd6f4`, luminance 0.676; the page's is 0.010. `scroll.offset` 690 before and after, and `scroll.total` 1654 before and after. | pass |
| **S40** The HTML card | The scratch P0 page. Console fill `12121b`; `bg0` (`11111b`) at 0.94 over the page's `1e1e1e` computes `12121b`. Log line `a6adc8` (`muted`), warning `f9e2af` (`amber`), error `f38ba8` (`consoleError`). The document's canvas `1e1e1e` and its block `ffffff`, as under Breeze Dark. The rule over the console `45475a` (`lineSoft`). | pass |
| **S41** Cards made under Mocha | One recording of 7 s, 420 frames: a doc opened with `tarmac open`, then a terminal made with ⌘T. No frame of the whole window holds a 4 × 4 flat area of `2b2f33` or `262a2f`, which are `31363b` and `2b3036` in a recording. At the new terminal's body: the board's value, then the Mocha body from the first frame of the card. At the new doc's header: the board, then the Mocha header. At two points of the new doc's page: the board, then `1b1b1b` for 6 frames, then the Mocha page. `1b1b1b` is the system's dark canvas (`1e1e1e`) in a recording: the web view before its page is drawn. The same 6 frames are there under Breeze Dark (one recording). See *Found on the way*. In a capture: new terminal body `1e1e2e`, its prime header `3b3c4f`. | pass: no Breeze Dark fill in a frame. The doc's page is not the Mocha page in its first 6 frames |
| **S42** Two boards, a culled card | First the reverse way: with the far cards culled and the second board away since Mocha, Breeze Dark was chosen. `zoom 0.2`: far terminal body `2e3338` (`31363b` under the 0.8 dim over the board computes `2e3338`), far doc page `2b3036`, far headers `353b41`, far P0 canvas `1e1e1e`. The second board: the five of Breeze Dark, prime header `3a4046`. Then the scenario. `tarmac dev focus` answers `card_hidden` for the far P0 card. `theme-of Dark "Catppuccin Mocha"`. The mounted board: the five of Mocha. `zoom 0.2`, first capture done 0.43 s after it was asked: far terminal body `1b1b2a` (`1e1e2e` under the 0.8 dim over `11111b` computes `1b1b2a`), far doc page `181825`, far doc header `313244`, far P0 canvas `1e1e1e`, far P0 header `313244`. The second board, first capture done 0.57 s after the switch was asked: five `11111b`, `313244`, `1e1e2e`, `181825`, `181825`; prime header `3b3c4f`. In the two 60 fps recordings each card has its Mocha value in the first frame in which it shows, and no frame of the whole window holds a 4 × 4 flat area of a Breeze Dark fill (terminal body, `bg1`, `bg2`, board). The doc page of the second board is `1b1b1b` for 1 frame before it is the Mocha page, and the far pages have 2 frames of a wrong scale (see *Found on the way*). | pass: no Breeze Dark fill in a frame |
| **S43** The eight themes | The table below. | pass |

S36, part by part. Every value is from a capture under Catppuccin Mocha.

| Part | Token | Mocha value | Sampled |
| --- | --- | --- | --- |
| Prime card's header | `primeHeaderBg` | `3b3c4f` | `3b3c4f` |
| Header, not prime (a doc card) | `bg2` | `313244` | `313244`; title text `a6adc8` (`muted`) |
| Border, not selected | `line` | `585b70` | `585b70` |
| Border, selected (the prime terminal) | `agent` at 0.5 over the card's fill `1e1e2e` | `598082` | `598081` |
| Border, selected, on a fresh doc card | `agent` at 0.5 over the fresh ring (`agent` at 0.16) over `1e1e2e` | `62908f` | `628f8f` |
| Status bar | `bg1`; rule `lineSoft` | `181825`; `45475a` | `181825`; `45475a`; text `7f849c` (`faint`) and `a6e3a1` (`ok`) |
| Zoom control | `bg2`; border `line`; rules `lineSoft` | `313244`; `585b70`; `45475a` | the same three; text `cdd6f4` |
| Minimap | `bg0` at 0.92 over the board; border `line`; view stroke `agent` | `11111b`; `585b70`; `94e2d5` | the same three. View fill `263239` (`agent` at 0.16 computes `263239`); a card under it `52606e` (`bg3` under the view fill computes `52606e`); a card out of the view `45475a` (`bg3`); the prime card `7ebfb6` (computes `7ebfb6`); a bell card `d7c299` (`amber` at 0.85 computes `d6c399`) |
| Provenance edge | `agent` at 0.7 over the board | `6da39d` | the fullest pixel of a dash `6da39d`; on three other dashes `699d98` to `6ca19b`. The line is 1.5 points wide, so most of its pixels are part covered |
| Toast, put up after the change | `bg2`; border `line` | `313244`; `585b70` | `313244`; `585b70`; title `cdd6f4` (`text`) |
| Off-screen hint (two, each for a bell) | `bg2`; border `amber` at 0.5 over `bg2` | `313244`; `958a7a` | `313244`; `958a79` on the straight part of the border; text `cdd6f4` (`text`) |
| Switcher: query line and footer | `bg1`; rules `lineSoft` | `181825`; `45475a` | `181825`; `45475a`; text `7f849c`, caret `94e2d5` |
| Switcher: a row, the selected row | `bg2`, `bg3`; border `line` | `313244`, `45475a`; `585b70` | `313244`, `45475a`; `585b70`; names `cdd6f4` and `94e2d5` |
| Console of the HTML card | `bg0` at 0.94 over the page; rule `lineSoft` | `12121b`; `45475a` | `12121b`; `45475a`; log `a6adc8`, warning `f9e2af`, error `f38ba8` |
| Owner chip | border `lineSoft`; text `faint` | `45475a`; `7f849c` | `45475a`; `7f849c` |
| Repo dot | `repoColors` | entry 3 `cba6f7`, entry 2 `89b4fa` | `cba6f7` (this repository, and one throwaway repository); `89b4fa` (the other) |
| Scroll thumb, a long doc | `scrollThumb`; `scrollThumbLine` | `181b1d`; `696b6c` | `181b1d`; `696b6c` |
| Scroll thumb, a terminal with scrollback | the same | `181b1d`; `696b6c` | `181b1d`; `696b6c` |

In Catppuccin Mocha `lineSoft` and `bg3` are one value, `45475a`. So the
switcher's rule and its selected row are not told apart by value: the
capture shows a band of 27 rows of pixels for the selected row and 1 row for
the rule. The switcher's veil over the board is dark, as before.

S43, theme by theme. Each theme was chosen with `theme <appearance>` and
`theme-of <appearance> <title>`. Every difference is 0.

| Theme | Snapshot's `theme` | Board | Doc header | Terminal body | Status bar | Doc page | Prime header |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Breeze Light | `{"choice":"light","in_effect":"light","name":"breeze-light"}` | `e3e5e7` | `dee0e2` | `fcfcfc` | `eff0f1` | `eff0f1` | `d0d4d8` |
| Catppuccin Latte | `{"choice":"light","in_effect":"light","name":"catppuccin-latte"}` | `dce0e8` | `ccd0da` | `eff1f5` | `e6e9ef` | `e6e9ef` | `c4c8d3` |
| GitHub Light | `{"choice":"light","in_effect":"light","name":"github-light"}` | `eaeef2` | `e1e6eb` | `ffffff` | `f6f8fa` | `f6f8fa` | `d8dee4` |
| Solarized Light | `{"choice":"light","in_effect":"light","name":"solarized-light"}` | `eee8d5` | `e5e1cf` | `fdf6e3` | `f6efdc` | `f6efdc` | `dedbca` |
| Breeze Dark | `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}` | `24282c` | `353b41` | `31363b` | `2b3036` | `2b3036` | `3a4046` |
| Catppuccin Mocha | `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}` | `11111b` | `313244` | `1e1e2e` | `181825` | `181825` | `3b3c4f` |
| GitHub Dark | `{"choice":"dark","in_effect":"dark","name":"github-dark"}` | `010409` | `161b22` | `0d1117` | `070a10` | `070a10` | `1c2028` |
| Solarized Dark | `{"choice":"dark","in_effect":"dark","name":"solarized-dark"}` | `001e26` | `073642` | `002b36` | `00252e` | `00252e` | `0f3c47` |

The five values of each row are the values of that theme's table in the
spec. The prime header is not asked for by S43; it is each theme's
`primeHeaderBg`.

### The appearance that is not in effect

A tile's picture is 66 × 44 points, 5 points in from the left edge and from
the top edge of the tile's frame that `rows` prints. This was checked on the
pixels of the *Light* tile. The two sample points are 4 points in from the
middle of the picture's left edge and of its right edge.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S44** A light theme while the choice is *Dark* | Before: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, the five of Breeze Dark, file `{"warn_before_quit":true}`, pictures *Auto* `e3e5e7` at the left and `24282c` at the right, *Light* `e3e5e7`, *Dark* `24282c`. `theme-of Light "GitHub Light"`. After: the same snapshot; the same five; 0 pixels of the whole main window differ between the two captures; file `{"warn_before_quit":true,"theme_light":"github-light"}`; `rows`: `0 selected=GitHub Light`, `1 selected=Breeze Dark`, tile *Dark* value 1. Pictures: *Light* `eaeef2`; *Auto* `eaeef2` at the left and `24282c` at the right, and its left half is now the left half of the *Light* picture, pixel for pixel; the *Dark* picture and the right half of *Auto* have a difference of 0. | pass |
| **S45** The *Light* tile | `theme Light`. Snapshot: `{"choice":"light","in_effect":"light","name":"github-light"}`. Five: `eaeef2`, `e1e6eb`, `ffffff`, `f6f8fa`, `f6f8fa`. `rows`: `0 selected=GitHub Light`, `1 selected=Breeze Dark`, as before the press; tile *Light* value 1. The three pictures: largest difference 0 between the capture before the press and the one after, on the 2648 pixels of each picture that are not in a corner. The four corners, 8 × 8 pixels each, are left out: they hold the window's fill, which changes with the appearance. | pass |
| **S46** The pictures of two chosen themes | GitHub Light and Catppuccin Mocha chosen, the choice *Light*. *Dark* picture `11111b` at the left point (and at the right one). *Auto* picture `eaeef2` at the left point and `11111b` at the right point. *Light* picture `eaeef2`. A 5 × 5 square round each point holds one colour. | pass |

### The file, live

| Scenario | Observed | Result |
| --- | --- | --- |
| **S47** A relaunch | File before the quit: `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme":"auto","theme_light":"solarized-light","theme_dark":"catppuccin-mocha"}`. Quit by pid, `make run`. First snapshot: `{"choice":"auto","in_effect":"light","name":"solarized-light"}`; the Mac is Light. The first capture, made at once after that snapshot, holds no flat area of a Breeze fill, dark or light. Five: `eee8d5`, `e5e1cf`, `fdf6e3`, `f6efdc`, `f6efdc`. `rows`: `0 selected=Solarized Light`, `1 selected=Catppuccin Mocha`, tile *Auto* value 1. The file's SHA-1 is the same after the launch. | pass |
| **S48** The members that were there | File written while the app was down: `{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":15,"theme":"light"}`. After the launch: the same bytes; `theme` `{"choice":"light","in_effect":"light","name":"breeze-light"}`; `fonts.terminal` `{"face":"Menlo-Regular","saved":"Menlo","size":15}`; the guard off. `theme-of Dark "GitHub Dark"`. File: `{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":15,"theme":"light","theme_dark":"github-dark"}`. The snapshot's `theme` did not change. | pass |
| **S49** *Auto* follows the Mac | Not run: it needs the Mac's appearance changed. Left to the user. | not run |

### Error scenarios

| Scenario | Observed | Result |
| --- | --- | --- |
| **S50** Ids that are not themes | File written while the app was down: `{"warn_before_quit":true,"terminal_font":"Menlo","theme_light":"catppuccin-mocha","theme_dark":"sepia"}`. Snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`; `fonts.terminal.saved` `Menlo`. `rows`: `0 selected=Breeze Light`, `1 selected=Breeze Dark`, tile *Dark* value 1. The five of Breeze Dark. After the launch and after both panes showed, the file's SHA-1 and its modification time are the same. Then *Warn Before Quitting (⌘Q)* chosen in the app menu: file `{"warn_before_quit":false,"terminal_font":"Menlo"}`. | pass |
| **S51** The file cannot be saved | Breeze Dark in effect, file `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme_light":"solarized-light"}`. The channel directory made mode 555 with the app up. `theme-of Dark "GitHub Dark"`: snapshot `{"choice":"dark","in_effect":"dark","name":"github-dark"}`; five `010409`, `161b22`, `0d1117`, `070a10`, `070a10`; `rows`: `1 selected=GitHub Dark`; one new stderr line, `tarmac: could not save app prefs: … Code=513 …`, where there was none; the file's SHA-1 and modification time are the same; the same two windows; the app runs on. | pass |
| **S52** `make qa` | Launch A, a fresh board, nothing saved, before the Settings window was shown: 27 of 27 checks pass, S21 skipped (the dev app was in front). No check fails, so no check that passes on `f683657` fails here. The channel held no `app-prefs.json` after it. `theme-qa.md` has 27 of 27, S21 skipped, for #209; `f683657` was not built in this run. | pass |

### Added at the review

| Scenario | Observed | Result |
| --- | --- | --- |
| **S53** A theme that is already chosen | Mocha saved and in effect. `theme-of Dark "Catppuccin Mocha"` again: the file's modification time is the same to the nanosecond, the same SHA-1, the same snapshot. And on the fresh channel of launch B, before any other choice: `theme-of Light "Breeze Light"` and `theme-of Dark "Breeze Dark"`; the directory still holds no `app-prefs.json`, and the snapshot is the one of S34. | pass |
| **S54** Back to the standard theme | From Mocha, `theme-of Dark "Breeze Dark"`, no restart. Snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`. Five: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. `rows`: `1 selected=Breeze Dark`. File: `{"warn_before_quit":true}`. In a 60 fps recording the five points change in one frame. | pass |
| **S55** The menus | The open menu of the *Light theme* pop-up, by region. Choice *Light* (GitHub Light, and again Solarized Light): fill `f1f2f3`, text `242425`; luminance 0.887 and 0.018. Choice *Dark* (Mocha): fill `242e3b`, text `e0e0e0`; luminance 0.026 and 0.745. The open menu of the *Dark theme* pop-up under *Dark* is dark with light text too (its fill is near `2a2b2e`). A menu's fill is a material, so its value changes a little with what is behind it. The Mac was Light for both halves. | pass, on a light Mac |
| **S56** The verbs of today | `pane Fonts`. `pick 0 Monaco`: `fonts.terminal` `{"face":"Monaco","saved":"Monaco","size":16}`. `step 0 up`: size 16.5. `size 1 17`: `fonts.document.size` 17. File: `{"warn_before_quit":true,"terminal_font":"Monaco","terminal_font_size":16.5,"document_font_size":17,"theme_light":"solarized-light"}`. `pane Theme`, `theme Light`: `rows` prints `tile Light value=1`, and 0 for the other two. Each verb ended with status 0. | pass |

## Found on the way

- **The fills change 0.25 s after the item is pressed.** In a 60 fps
  recording of a choice: the menu is up for 28 frames, the harness presses
  the item and ends, the menu goes out over 9 frames, and the board, the
  status bar and the terminal body change in one frame, 15 frames after the
  press. So a capture made at once after `theme-of` comes back has the old
  theme (S35), and a snapshot read after that capture has the new one. The
  menu is gone 9 frames after the press, and the fills change 6 frames after
  that. Wait 1 s before the capture.
- **A new doc card shows the system's dark canvas for 6 frames.** S41. For
  100 ms the card's page is `1e1e1e`, then it is the theme's `bg1`. It is
  the same under Breeze Dark, so it is not from this change, and it is not a
  Breeze fill. For a doc that comes back with its board it is 1 frame (S42).
  It was not measured under a light theme.
- **Two frames of a wrong scale after a zoom.** S42. 8 frames after
  `zoom 0.2` from zoom 1, the pages of the far doc card and of the far P0
  card are drawn many times too large for 2 frames, and then at their right
  size. The colours in those frames are the theme's own. It is the same
  under Breeze Dark and under Mocha. `theme-qa.md` has a note of the same
  kind (*One frame without the block*). Not from this change.
- **The board is darker near a card.** A card's shadow reaches about 35
  points past its edge. Under GitHub Dark the board 20 points above a card
  reads `010308`, and under Solarized Dark `001d25`, in flat squares of
  7 × 7 pixels, so the test for one colour does not see the shadow in a
  dark theme. Clear of the cards the board is `010409` and `001e26`. Sample
  the board 100 points or more from a card.
- **The snapshot has no selection for selected empty cells.** S37: the
  capture shows the selection, and `term.selection` is `null` before and
  after the change. The selection holds no text.
- **A tile's picture has round corners.** S45 compares the pictures without
  their corners, for the reason in its row.
- **No hint of a running program was sampled.** On this Mac each new
  terminal has a bell from the first prompt of the shell, so the two far
  terminals both had a bell hint, the one that ran `sleep` too.
- **`lineSoft` and `bg3` are one value** in Catppuccin Mocha (`45475a`), and
  also in Catppuccin Latte, GitHub Light, GitHub Dark and Solarized Dark by
  the spec's tables. A rule beside a selected row cannot be told from it by
  value there.
- **A size that was typed stays in the file.** After `size 0 16` and
  `size 1 14`, which are the standard sizes, the file holds
  `"terminal_font_size":16,"document_font_size":14`. This is not a matter of
  the theme and was not checked against spec 2610.0006.
- For a later run:
  - The main window comes back at 1100 × 732 after a launch. Set its size
    again before a capture.
  - `wheel-gesture` needs the main window to be key: run
    `tarmac dev focus board` first when the Settings window was used last.
  - A compiled `wheel-gesture` finds the debug CLI from the directory it is
    run in: run it from the repository's root.
  - Zoom in does not cull a card that is in the window at zoom 1. To have a
    culled card, drag a terminal by its header at zoom 0.5, two times, until
    it is more than one viewport past the window's edge, and open the cards
    from it at zoom 0.2.

## Not covered

- S49, and every half of a scenario that needs a Mac whose appearance is
  Dark: *Auto* on a dark Mac (S47), and the menus under *Light* on a dark
  Mac (S55).
- A build of `f683657`: the Settings window's frame (S33) and `make qa`
  (S52) on it are from `theme-qa.md`.
- S36 under a theme other than Catppuccin Mocha. S43 has the five fills and
  the prime header for each of the eight.
- S41 and S42 under a light theme, and a far card brought into view by a
  pan.
- The host page's backdrop of an HTML card after a change: it is not on
  screen (the spec's *Trade-offs and Limitations*).
- A 2× display, and a display with another colour profile.
- `make qa` under a theme other than Breeze Dark.

## The run of revision 2 (2026-10-07)

The live half of revision 2 of
[spec 2610.0008](../.blueprint/specs/2610.0008_theme_choice.md): its 31
`[QA]` scenarios, S33 to S56 and S65 to S71, with the values observed.
Revision 2 has a list of themes and a showcase in place of the two pop-ups
(D8), lets any theme be chosen for any appearance (D9), and takes the app's
appearance from the theme in effect (D10). Every `[QA]` scenario was run
again, the ones with no change of text too.

It is also the live check for the shell of revision 2: `ThemeSettings`,
`ThemePane`, the list, the swatch and the showcase's picture
(`ThemeList`, `ThemePicture`), `SettingsSidebar`, `SettingsGroup`, and the
verbs `show`, `apply` and `rows` of
[`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift).

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.
The method is the one of the run of revision 1, above, and of
[`theme-qa.md`](theme-qa.md).

**Result:** 31 scenarios were run. 31 pass. None fails. None was not run.
No code was changed in this run. Seven rows pass with a limit that the row
gives:

- S41: no frame holds a Breeze Dark fill, which is the test the scenario
  names. But the page of a new doc card is the system's dark canvas for 3 to
  8 frames, and in 2 of 11 recordings under Mocha it is then white for 1 or
  2 frames, before it is the theme's page. Under Breeze Dark it is the same:
  1 of 9 recordings. See *Found on the way*.
- S33 and S52: the values for `c6229ea` and `f683657` are from the earlier
  records, not from builds of those commits.
- S66: the part of the doc that the template does not style is the rule. It
  has the same two values under Breeze Light too, so that point of the
  scenario cannot fail. The canvas of the HTML card is the point that tells
  dark from light.
- S71: the first `key 13` did not close the Settings window, because the dev
  app was not the active app. It was run again with the Settings window made
  key through Accessibility. See *Found on the way*.
- S49 and S69: the Mac was changed by a script, three times, for 2.6 s,
  3.1 s and 7.8 s. The automatic change at sunset was not run.

**Run:** 2026-10-07, macOS 26.7 (25G229), a `make run` debug build of the
branch `feat/217-choose-light-dark-theme`: the commit `08e44de` and the
working tree on it, which was not committed. One build served the whole run.
Main display: BenQ EW2770QZ at 1×, with its own colour profile
(`BenQ EW2770QZ`). Every capture of a window of the dev app was made while
that window was on this display, so a point is a pixel. A second display
(the built-in panel, at 2×, profile `Color LCD`) was connected. The Settings
window was put on it for the recordings of S42 and of the first of S41, and
no capture of it was made there. A fresh dev channel, `.dev/qa217b`, removed
after the run.

**The Mac's appearance.** Light at the start: `dark mode` read through
System Events was `false`, and the preference `AppleInterfaceStyle` had no
value. It was changed in S49 and S69 only, with System Events, under the
leave of the spec's D10. It was Dark for 13.5 s in all, in three spans. It
was set back to Light, and the last read of `dark mode` was `false` and the
preference had no value again. S33, S55, S66 and S68 ran while it was Light.

There were eight launches on that channel:

| Launch | State at the start | Scenarios |
| --- | --- | --- |
| A | fresh channel | S52 only. The app and its daemon were then stopped and the channel was made empty. |
| B | fresh channel | S34, S33, S70, S53 (its second and third parts), S55 (first state), S65, then the board, then S35, S37, S39, S40, S42, S36, S38, S41, S53 (first part), S71, S54, S43, S44, S45, S46, S56, S55 (second and third state), S66 |
| C | the files of B, the same daemon | S47, S51, S69, and S49 but for its launch step |
| D | the files of C, the same daemon, started while the Mac was Dark | the launch step of S49 |
| E | a prepared `app-prefs.json`, the same daemon | S68 |
| F | a prepared `app-prefs.json`, the same daemon | S48 |
| G | a prepared `app-prefs.json`, the same daemon | S50. The app and its daemon were then stopped and the channel was made empty. |
| H | fresh channel | S67, and then five more recordings for S41 under Breeze Dark |

### The capture tolerance of this run

The tolerance is 1 for each channel, as in the two earlier records. It was
checked again on this tree, on the fresh channel of launch B, with Breeze
Dark. This change must not change the values of Breeze Dark, so they are a
known input.

| Fill | Value | Sampled, 4 points each |
| --- | --- | --- |
| board | `24282c` | `24282c` |
| doc card header | `353b41` | `353b41` |
| terminal body | `31363b` | `31363b` |
| status bar | `2b3036` | `2b3036` |
| doc page | `2b3036` | `2b3036` |

The largest difference in a channel is 0, at 20 points. Each 7 × 7 square
round a point held one colour. No sampled value in this run that is held to
a token is more than 1 from it. The file that `screencapture` writes is
tagged `sRGB IEC61966-2.1`, and its bytes are read as they are.

### What this run uses

- `tarmac dev snapshot`, and a capture by `screencapture -o -l <window id>`
  of a window of the app's pid, as in the run of revision 1. An open menu is
  captured by region (`screencapture -R`).
- The main window was made 1830 × 1250 through Accessibility after each
  launch. It comes back at 1100 × 732.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift),
  compiled once: `open`, `rows`, `pane`, `theme`, `show`, `apply`, `pick`,
  `size`, `step`, `move`, `menu`, `key`. The verb `theme-of` does not exist.
- **A refused `apply`.** `apply` prints the box line on stdout and, when it
  presses nothing, a message on stderr, and exits 1. Where the spec says
  "its last line", this record reads the last line of stdout.
- **The picture's frame.** The `picture frame=` line of `rows` gives
  362 × 226 points. The drawn image is 360 × 224, and starts 1 point in from
  the frame's left edge and 1 point down from its top edge. The three sample
  points of S65 are offsets from the frame's origin, chosen once from a
  capture of Breeze Dark and used for all eight themes: the board at
  (6, 113), the terminal card's body at (150, 150), the doc card's page at
  (280, 150). Each is the middle of a 7 × 7 square of one colour.
- **A tile's picture** is 66 × 44 points, 5 points in from the left edge and
  from the top edge of the tile's frame that `rows` prints. This was checked
  again on the pixels of the *Light* tile of the new pane.
- *The Settings window is dark* or *light*: the pane's fill 40 points right
  of the label *Appearance*, and the fullest pixel of that label, compared
  by luminance. The row gives both values.
- [`theme-doc.md`](theme-doc.md) at 392 × 500, scrolled to its middle. The
  scratch page of the run of revision 1 as P0 of
  [`html-card-scheme/`](html-card-scheme/README.md): it states no colour
  scheme and no colour, and has one console line of each level. Scratch
  docs, and one doc in each of two throwaway repositories.
- [`scripts/qa/wheel-gesture.swift`](../scripts/qa/wheel-gesture.swift)
  scrolls a selected card and shows its scroll thumb.
- A drag is posted at the HID tap: to move a card by its header, and to
  select empty cells of a terminal. A click at the HID tap opened the
  console of the HTML card.
- A scratch script in a terminal card sends the colour queries and logs the
  answers.
- A recording is 60 fps `ffmpeg` of the screen device `Capture screen 0`. Its
  colours are not sRGB values. A recording is searched for the Breeze Dark
  fills as a recording has them (board `202327`, header `2e3339`, terminal
  body `2b2f33`, status bar and doc page `262a2f`), with a tolerance of 1.
  The Mocha fills in a recording are: board `111119`, header `2b2c3b`,
  terminal body `1b1b28`, status bar and doc page `171721`. The system's
  dark canvas (`1e1e1e`) is `1b1b1b` there.
- Scratch tools that read through Accessibility: which window of the app is
  key, and the close button of a window. One makes the Settings window the
  main window of the app (`AXRaise`, `AXMain`).

*Five* in a row means the five fills in the spec's order: board, doc card
header, terminal body, status bar, doc page. The board is sampled 100 points
or more from a card.

### The window (revision 2)

| Scenario | Observed | Result |
| --- | --- | --- |
| **S33** The pane | Fresh channel, the Mac Light, ⌘,: `pane=Fonts`. `pane Theme`: `pane=Theme`. The capture shows the row *Appearance* with the tiles *Auto*, *Light*, *Dark*, and under it the list and the showcase. `rows` prints eight `theme` lines, in this order: `theme Breeze Light marks=Light selected=0`, `theme Breeze Dark marks=Dark selected=1`, then Catppuccin Latte, Catppuccin Mocha, GitHub Light, GitHub Dark, Solarized Light, Solarized Dark, each with `marks=` empty and `selected=0`. `showcase title=Breeze Dark caption=dark theme`. `box Apply to Light value=0 enabled=1`. `box Apply to Dark value=1 enabled=0`. `note 5 terminal colours have low contrast on the background.` **The frame:** `window frame=847.0,260.0 873.0x488.0` on *Fonts*, on *Theme*, on *Fonts*, on *Theme*, on *Fonts* and on *Theme*. On `c6229ea` it was 691 × 299 (the run of revision 1; that commit was not built here). 873 is more than 691 and 488 is more than 299. `resizable=false` on both panes. Every frame that `rows` prints lies inside the window's frame: 31 frames on *Theme* (the tiles, the eight rows, the picture, the two boxes, the labels) and 17 on *Fonts*. The eight rows are 24 points each, from y 423 to y 615 in a window that ends at y 748, and the capture shows all eight whole, with no scroller. A capture of each pane shows each control whole. The window was moved later in the run (see *Found on the way*); the four reads were made again at the new place and gave 873 × 488 each time, and all frames inside. | pass (the `c6229ea` frame is from the earlier record) |
| **S34** A fresh channel | First snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`. Five: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. The channel's directory holds the two sockets, `state.json` and `tarmacd.log`, and no `app-prefs.json`, also after the doc card was opened. | pass |

### A choice (revision 2)

The board of launch B, made under Breeze Dark: a terminal with the lines of
S37 and a selection over empty cells, `theme-doc.md` at 392 × 500 with
`scroll.offset` 652, the scratch P0 page with its console open, a second
terminal with 300 lines of scrollback, two docs of two repositories, and far
to the right a terminal, a doc and a P0 page that are culled at zoom 1
(`tarmac dev focus` answers `card_hidden` for the far P0 card). A second
board with a terminal and a doc.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S35** Breeze Dark to Catppuccin Mocha | Before: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, file `{"warn_before_quit":true}`. `show "Catppuccin Mocha"` prints `shown Catppuccin Mocha`; `apply Dark on` prints `box Apply to Dark value=1 enabled=1`, status 0. No restart. Snapshot: `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}`. File: `{"warn_before_quit":true,"theme_dark":"catppuccin-mocha"}`. Five, in a capture 1.2 s after the box: `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. `rows`: `marks=Dark` on Catppuccin Mocha, `marks=` empty on Breeze Dark, `marks=Light` on Breeze Light, `box Apply to Dark value=1 enabled=1`. | pass |
| **S36** Each part | The table below. No capture of the main window under Mocha holds a 4 × 4 flat area of a fill that only Breeze Dark has (11 captures scanned for the eight values, tolerance 0). | pass |
| **S37** Text already drawn | No key in the terminal after the choice. Full block `cdd6f4` (it was `ced2d6`). The sixteen backgrounds, 0 to 15: `45475a` `f38ba8` `a6e3a1` `f9e2af` `89b4fa` `f5c2e7` `94e2d5` `bac2de` `585b70` `f7aec2` `c2ecbf` `fcd682` `aeccfc` `f398da` `b1eae1` `a6adc8`: the spec's table (under Breeze Dark they were `232627` `ed1515` `11d116` … `ffffff`). ANSI 2 background `a6e3a1`. Body `1e1e2e`. Selected empty cell `415960` (it was `2a5e58`); `1e1e2e` with `94e2d5` at 0.3 computes `415960`. Grid 44 × 14 before and after. | pass |
| **S38** The answers | Mocha: `rgb:cdcd/d6d6/f4f4`, `rgb:1e1e/1e1e/2e2e`, `rgb:f5f5/e0e0/dcdc`, `rgb:a6a6/e3e3/a1a1`, `CSI ? 997 ; 1 n`. *Light* with Solarized Light: `rgb:6565/7b7b/8383`, `rgb:fdfd/f6f6/e3e3`, `rgb:6565/7b7b/8383`, `rgb:8585/9999/0000`, `CSI ? 997 ; 2 n`. Each colour answer came with the `ST` end. | pass |
| **S39** A doc keeps its place | Page `181825` (it was `2b3036`). Code block `1e1e2e` (it was `31363b`). The fullest pixel of the heading *The parts* is `cdd6f4`, luminance 0.676; the page's is 0.010. `scroll.offset` 652 and `scroll.total` 1654 before and after. | pass |
| **S40** The HTML card | The scratch P0 page. Console fill `12121b` (it was `24272b`); `bg0` (`11111b`) at 0.94 over the page's `1e1e1e` computes `12121b`. Log line `a6adc8` (`muted`), warning `f9e2af` (`amber`), error `f38ba8` (`consoleError`). The rule over the console `45475a` (`lineSoft`). The document's canvas `1e1e1e` and its block `ffffff`, as under Breeze Dark. | pass |
| **S41** Cards made under Mocha | One recording of 8 s, 480 frames: a doc opened with `tarmac open`, then a terminal made with ⌘T. No frame of the whole window holds a 4 × 4 flat area of `2b2f33` or `262a2f`, which are `31363b` and `2b3036` in a recording, nor of the board or the header of Breeze Dark. The new terminal's body, at two points: the board's value, then the Mocha body from the first frame of the card. The new doc's header: the board, then the Mocha header. The new doc's page, at two points: the board, then `1b1b1b` for 3 frames, then `ffffff` for 2 frames, then the Mocha page. `1b1b1b` is the system's dark canvas in a recording. The white frames show the whole page of the card white, under its Mocha header. Ten more recordings of a doc opened under Mocha (5 s each, the doc's page at two points): the dark canvas for 4 to 8 frames in each; one of them has 1 white frame after it, and nine have none. So under Mocha: 5 recordings of a file that was never opened before, 2 with white frames; 6 of a file opened again, none. Under Breeze Dark, nine recordings, the dark canvas for 4 to 7 frames in each: 5 of a file never opened before, 1 with 2 white frames; 4 of a file opened again, none. In a capture after the recording: new terminal body `1e1e2e`, new doc header `313244`, new doc page `181825`. | pass by the test the scenario names: no Breeze Dark fill in a frame. The doc's page is not the Mocha page in its first 3 to 8 frames, and in 2 of 11 recordings it is white for 1 or 2 frames. Breeze Dark has the same white frames (1 of 9) |
| **S42** Two boards, a culled card | With the far cards culled and the second board away since Breeze Dark, Catppuccin Mocha was chosen (the choice of S35). Then one recording of 9 s, 540 frames: `zoom 0.2`, `zoom 1`, the switcher, the second board. No frame of the whole window holds a 4 × 4 flat area of a Breeze Dark fill (terminal body, `bg1`, `bg2`, board). **The far cards**, in the first frame in which they show and in every frame after it: terminal body `191925` and terminal header `252634` (a recording's values of the dimmed card), doc header `2b2c3b`, doc page `171721` at two points, P0 header `2b2c3b`, P0 canvas `1b1b1b`. In the capture made 0.37 s after `zoom 0.2` was asked: far terminal body `1b1b2a` (`1e1e2e` under the 0.8 dim over `11111b` computes `1b1b2a`), far terminal header `2b2b3c` (`313244` under the same dim computes `2b2b3c`), far doc header `313244`, far doc page `181825`, its code block `1e1e2e`, far P0 header `313244`, far P0 canvas `1e1e1e`. A point of the far doc's code block reads the page's value for 2 frames, 8 frames after the zoom (the frames of a wrong scale that the run of revision 1 has). **The second board:** one frame with the board's fill and no card, then each card with its Mocha value from its first frame: terminal body `1b1b28`, doc header `2b2c3b`, doc page `171721`. In the capture made 0.36 s after the switch was asked: five `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. | pass |
| **S43** The eight themes | The table below. | pass |

S36, part by part. Every value is from a capture under Catppuccin Mocha.

| Part | Token | Mocha value | Sampled |
| --- | --- | --- | --- |
| Prime card's header | `primeHeaderBg` | `3b3c4f` | `3b3c4f` |
| Header, not prime (a doc card) | `bg2` | `313244` | `313244`; title text `a6adc8` (`muted`) |
| Border, not selected | `line` | `585b70` | `585b70` |
| Border, selected (the prime terminal, and a selected doc card) | `agent` at 0.5 over the card's fill `1e1e2e` | `598082` | `598081` |
| Status bar | `bg1`; rule `lineSoft` | `181825`; `45475a` | `181825`; `45475a`; text `7f849c` (`faint`) and `a6e3a1` (`ok`) |
| Zoom control | `bg2`; border `line`; rules `lineSoft` | `313244`; `585b70`; `45475a` | the same three; text `cdd6f4` and `7f849c` |
| Minimap | `bg0` at 0.92 over the board; border `line`; view stroke `agent` | `11111b`; `585b70`; `94e2d5` | the same three. View fill `263239` (`agent` at 0.16 computes `263239`); a card under it `52606e` (`bg3` under the view fill computes `52606e`); a card out of the view `45475a` (`bg3`); the prime card `7ebfb6`; a bell card `d7c299` (`amber` at 0.85 computes `d6c399`) |
| Provenance edge | `agent` at 0.7 over the board | `6da39d` | the fullest pixel of a dash `6da39d` on two edges, `679a94` on a third. The line is 1.5 points wide, so most of its pixels are part covered |
| Toast, put up after the change (a shell that ended with status 3) | `bg2`; border `line` | `313244`; `585b70` | `313244`; `585b70`; title `cdd6f4` (`text`) |
| Off-screen hint (a bell) | `bg2`; border `amber` at 0.5 over `bg2` | `313244`; `958a7a` | `313244`; `958a79` on the straight part of the border; text `cdd6f4` (`text`), arrow `f9e2af` (`amber`) |
| Switcher: query line and footer | `bg1`; rules `lineSoft` | `181825`; `45475a` | `181825`; `45475a`; text `7f849c`, caret `94e2d5` |
| Switcher: a row, the selected row | `bg2`, `bg3`; border `line` | `313244`, `45475a`; `585b70` | `313244`, `45475a`; `585b70`; names `94e2d5` and `cdd6f4`, meta `7f849c` |
| Console of the HTML card | `bg0` at 0.94 over the page; rule `lineSoft` | `12121b`; `45475a` | `12121b`; `45475a`; log `a6adc8`, warning `f9e2af`, error `f38ba8` |
| Owner chip | border `lineSoft`; text `faint` | `45475a`; `7f849c` | `45475a`; `7f849c` |
| Repo dot | `repoColors` | entry 3 `cba6f7`, entry 2 `89b4fa` | `cba6f7` (this repository, and one throwaway repository); `89b4fa` (the other) |
| Scroll thumb, a long doc | `scrollThumb`; `scrollThumbLine` | `181b1d`; `696b6c` | `181b1d`; `696b6c` |
| Scroll thumb, a terminal with scrollback | the same | `181b1d`; `696b6c` | `181b1d`; `696b6c` |

In Catppuccin Mocha `lineSoft` and `bg3` are one value, `45475a`: the
switcher's rule and its selected row are told apart by their place, as in
the run of revision 1.

S43, theme by theme. Each theme was applied with `theme <appearance>`,
`show <title>` and `apply <appearance> on`. For Breeze Light and Breeze Dark
no `apply` was sent: the box was on already. Every difference is 0.

| Theme | Snapshot's `theme` | Board | Doc header | Terminal body | Status bar | Doc page | Prime header |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Breeze Light | `{"choice":"light","in_effect":"light","name":"breeze-light"}` | `e3e5e7` | `dee0e2` | `fcfcfc` | `eff0f1` | `eff0f1` | `d0d4d8` |
| Catppuccin Latte | `{"choice":"light","in_effect":"light","name":"catppuccin-latte"}` | `dce0e8` | `ccd0da` | `eff1f5` | `e6e9ef` | `e6e9ef` | `c4c8d3` |
| GitHub Light | `{"choice":"light","in_effect":"light","name":"github-light"}` | `eaeef2` | `e1e6eb` | `ffffff` | `f6f8fa` | `f6f8fa` | `d8dee4` |
| Solarized Light | `{"choice":"light","in_effect":"light","name":"solarized-light"}` | `eee8d5` | `e5e1cf` | `fdf6e3` | `f6efdc` | `f6efdc` | `dedbca` |
| Breeze Dark | `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}` | `24282c` | `353b41` | `31363b` | `2b3036` | `2b3036` | `3a4046` |
| Catppuccin Mocha | `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}` | `11111b` | `313244` | `1e1e2e` | `181825` | `181825` | `3b3c4f` |
| GitHub Dark | `{"choice":"dark","in_effect":"dark","name":"github-dark"}` | `010409` | `161b22` | `0d1117` | `070a10` | `070a10` | `1c2028` |
| Solarized Dark | `{"choice":"dark","in_effect":"dark","name":"solarized-dark"}` | `001e26` | `073642` | `002b36` | `00252e` | `00252e` | `0f3c47` |

The five values of each row are the values of that theme's table in the
spec. The prime header is not asked for by S43; it is each theme's
`primeHeaderBg`.

### The appearance that is not in effect (revision 2)

| Scenario | Observed | Result |
| --- | --- | --- |
| **S44** A light theme while the choice is *Dark* | Before: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, the five of Breeze Dark, file `{"warn_before_quit":true}`, pictures *Auto* `e3e5e7` at the left and `24282c` at the right, *Light* `e3e5e7`, *Dark* `24282c`. `show "GitHub Light"`, `apply Light on` (`box Apply to Light value=1 enabled=1`). After: the same snapshot; the same five; 0 of the 2 287 500 pixels of the main window differ between the two captures; file `{"warn_before_quit":true,"theme_light":"github-light"}`; `rows`: `marks=Light` on GitHub Light, `marks=` empty on Breeze Light, `marks=Dark` on Breeze Dark, `tile Dark value=1`. Pictures: *Light* `eaeef2`; *Auto* `eaeef2` at the left and `24282c` at the right, and its left half is the left half of the *Light* picture, pixel for pixel; the *Dark* picture and the right half of *Auto* have a difference of 0. | pass |
| **S45** The *Light* tile | `theme Light`. Snapshot: `{"choice":"light","in_effect":"light","name":"github-light"}`. Five: `eaeef2`, `e1e6eb`, `ffffff`, `f6f8fa`, `f6f8fa`. Before the press and after it `rows` prints the same marks (`Light` on GitHub Light, `Dark` on Breeze Dark), the same two lines `box Apply to Light value=1 enabled=1` and `box Apply to Dark value=0 enabled=1`, and the same selected row, GitHub Light; `tile Light value=1`. The three pictures: largest difference 0 between the capture before the press and the one after, on the 2648 pixels of each picture that are not in a corner. | pass |
| **S46** The pictures of two chosen themes | GitHub Light applied to Light and Catppuccin Mocha applied to Dark, the choice *Light*; file `{"warn_before_quit":true,"theme":"light","theme_light":"github-light","theme_dark":"catppuccin-mocha"}`. *Dark* picture `11111b` at the left point (and at the right one). *Auto* picture `eaeef2` at the left point and `11111b` at the right point. *Light* picture `eaeef2`. A 5 × 5 square round each point holds one colour. | pass |

### The file, live (revision 2)

| Scenario | Observed | Result |
| --- | --- | --- |
| **S47** A relaunch | File before the quit: `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme":"auto","theme_light":"solarized-light","theme_dark":"catppuccin-mocha"}`. Quit by pid, `make run`. First snapshot: `{"choice":"auto","in_effect":"light","name":"solarized-light"}`; the Mac is Light. The first capture, made at once after that snapshot, holds no flat area of a Breeze fill, dark or light. Five: `eee8d5`, `e5e1cf`, `fdf6e3`, `f6efdc`, `f6efdc`. Settings opened, `pane Theme`: `marks=Light` on Solarized Light, `marks=Dark` on Catppuccin Mocha, the selected row is Solarized Light, `showcase title=Solarized Light caption=light theme`, `tile Auto value=1`. The file's SHA-1 is the same after the launch. | pass |
| **S48** The members that were there | File written while the app was down: `{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":15,"theme":"light"}`. After the launch: the same bytes; `theme` `{"choice":"light","in_effect":"light","name":"breeze-light"}`; `fonts.terminal` `{"face":"Menlo-Regular","saved":"Menlo","size":15}`; the guard off. `show "GitHub Dark"`, `apply Dark on`. File: `{"warn_before_quit":false,"terminal_font":"Menlo","terminal_font_size":15,"theme":"light","theme_dark":"github-dark"}`. The snapshot's `theme` did not change. | pass |
| **S49** *Auto* follows the Mac | The table *S49 and S69, step by step* below. The Mac started Light. Every snapshot, every five and every read of the Settings window is the one the scenario asks for; the theme followed 0.4 s to 0.9 s after each change of the Mac; the file's SHA-1 is the same in every step of S49 (the `theme Light` of S69 changed the file between two of them, and `theme Auto` then wrote the same bytes as before); the selected row and the marks are the same after each change; the launch while the Mac was Dark read Solarized Light in its first snapshot. | pass |

### Error scenarios (revision 2)

| Scenario | Observed | Result |
| --- | --- | --- |
| **S50** Ids that are not themes | File written while the app was down: `{"warn_before_quit":true,"terminal_font":"Menlo","theme_light":"GitHub-Light","theme_dark":"sepia"}`. First snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`; `fonts.terminal.saved` `Menlo`. `rows`: `marks=Light` on Breeze Light, `marks=Dark` on Breeze Dark, the selected row Breeze Dark, `tile Dark value=1`. The five of Breeze Dark. After the launch and after both panes showed, the file's SHA-1 and its modification time are the same. Then *Warn Before Quitting (⌘Q)* chosen in the app menu: file `{"warn_before_quit":false,"terminal_font":"Menlo"}`. | pass |
| **S51** The file cannot be saved | Breeze Dark in effect, file `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme_light":"solarized-light"}`. The channel directory made mode 555 with the app up. `show "GitHub Dark"`, `apply Dark on` (`box Apply to Dark value=1 enabled=1`, status 0): snapshot `{"choice":"dark","in_effect":"dark","name":"github-dark"}`; five `010409`, `161b22`, `0d1117`, `070a10`, `070a10`; `rows`: `marks=Dark` on GitHub Dark; one new stderr line, `tarmac: could not save app prefs: … Code=513 …`, where there was none; the file's SHA-1 and modification time are the same; the same two windows; the app runs on. The directory was then made mode 755 again. | pass |
| **S52** `make qa` | Launch A, a fresh board, nothing saved, before the Settings window was shown, with the terminal's `proc` at `zsh`: 27 of 27 checks pass, S21 skipped (the dev app was in front). No check fails, so no check that passes on `f683657` fails here. The channel held no `app-prefs.json` after it. `theme-qa.md` has 27 of 27, S21 skipped, for #209; `f683657` was not built in this run. | pass |

### Added at the review (revision 2)

| Scenario | Observed | Result |
| --- | --- | --- |
| **S53** A selected row changes nothing, and the locked box | **First part.** Mocha saved and in effect, file `{"warn_before_quit":true,"theme_dark":"catppuccin-mocha"}`. `show` for each of the eight titles: after each one the file's modification time is the same to the nanosecond, its SHA-1 is the same, the snapshot's `theme` is `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}`, and the five are `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. **Second part.** On the fresh channel of launch B, `show` for each of the eight titles (each `shown <title>`, status 0): the directory holds no `app-prefs.json` after each one. **Third part.** With Breeze Dark shown, `rows` prints `box Apply to Dark value=1 enabled=0` and `box Apply to Light value=0 enabled=1`. (1) `apply Dark off`: status 1, last line `box Apply to Dark value=1 enabled=0`, stderr `the box Apply to Dark is disabled`. (2) `apply Dark on`: status 1, the same last line, the same stderr message. (3) `apply Light off`: status 1, last line `box Apply to Light value=0 enabled=1`, stderr `the box Apply to Light is already off`. (4) With Breeze Light shown, `rows` prints `box Apply to Light value=1 enabled=0`; `apply Light off`: status 1, last line `box Apply to Light value=1 enabled=0`, stderr `the box Apply to Light is disabled`. After the four: no `app-prefs.json`, the snapshot of S34, `marks=Light` on Breeze Light and `marks=Dark` on Breeze Dark. | pass |
| **S54** Back to the standard theme | From Mocha, with Catppuccin Mocha shown, `apply Dark off` (`box Apply to Dark value=0 enabled=1`, status 0), no restart. Snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`. Five: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. `rows`: `marks=Dark` on Breeze Dark, `marks=` empty on Catppuccin Mocha, `box Apply to Dark value=0 enabled=1`. File: `{"warn_before_quit":true}`. | pass |
| **S55** The Settings window follows the theme in effect | The Mac was Light for all of it. **First state**, a fresh channel with nothing saved (Breeze Dark): the fill beside *Appearance* is `2d2b2b`, luminance 0.025; the label is `dfdfdf`, 0.738: dark. **Second state**, the choice *Light* with GitHub Light applied to Light: fill `f7f7f7`, 0.930; label `262626`, 0.019: light. **Third state**, the choice *Light* with Catppuccin Mocha applied to Light, snapshot `{"choice":"light","in_effect":"dark","name":"catppuccin-mocha"}`: fill `343739`, 0.038; label `e0e0e1`, 0.746: dark. **The open menu** of the Terminal family pop-up of the Fonts pane, by region. Second state: fill `f9f9f9`, 0.947; text `252525`, 0.019: the fill is lighter. Third state: fill `212425`, 0.017; text `ffffff`, 1.0, on the selected item: the fill is darker. A fill of the window and of a menu is a material, so its value changes a little with what is behind it. | pass |
| **S56** The verbs of today | `pane Fonts`. `pick 0 Monaco` (`picked Monaco of 14`): `fonts.terminal` `{"face":"Monaco","saved":"Monaco","size":16}`. `step 0 up`: size 16.5. `size 1 17`: `fonts.document.size` 17. File: `{"warn_before_quit":true,"terminal_font":"Monaco","terminal_font_size":16.5,"document_font_size":17,"theme":"light","theme_light":"github-light","theme_dark":"catppuccin-mocha"}`. `pane Theme`, `theme Light`: `rows` prints `tile Light value=1`, and 0 for the other two. Each verb ended with status 0. | pass |

### Added in revision 2

| Scenario | Observed | Result |
| --- | --- | --- |
| **S65** The showcase | The choice *Dark*, Breeze Dark in effect, nothing saved. The table *S65, theme by theme* below: each `show` ends with status 0 and prints `shown <title>`; `rows` prints that row as the one selected row, the title, the caption and the note; the three points of the picture are the theme's `bg0`, `terminal.background` and `bg1`. After each `show` the five of the main window are `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036` and the snapshot's `theme` is `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`. Then `theme Light`: snapshot `{"choice":"light","in_effect":"light","name":"breeze-light"}`, the Settings window is light (fill `f7f7f7`, label `262626`). `show "GitHub Light"`: `eaeef2`, `ffffff`, `f6f8fa`. `show "Catppuccin Mocha"`: `11111b`, `1e1e2e`, `181825`. These are the values under the dark app. | pass |
| **S66** A dark theme for the light appearance | The Mac Light, the choice *Light*, Breeze Light in effect (`{"choice":"light","in_effect":"light","name":"breeze-light"}`, five `e3e5e7`, `dee0e2`, `fcfcfc`, `eff0f1`, `eff0f1`), a terminal card, `theme-doc.md` and the scratch P0 page. `show "Catppuccin Mocha"`, `apply Light on` (`box Apply to Light value=1 enabled=1`). No restart. Snapshot: `{"choice":"light","in_effect":"dark","name":"catppuccin-mocha"}`. File: `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme":"light","theme_light":"catppuccin-mocha"}`. Five: `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. The Settings window is dark: fill `343739`, 0.038; label `e0e0e1`, 0.746. `rows`: `marks=Light` on Catppuccin Mocha, `tile Light value=1`. The *Light* tile's picture `11111b` at the left point (the left half of *Auto* too; the *Dark* picture is `24282c`). The canvas of the P0 document is `1e1e1e` and its block `ffffff`; under Breeze Light they were `ffffff` and `000000`. **The part the template does not style** is the rule of `theme-doc.md`, read at zoom 3, where each of its two lines is one row of pixels: upper line `2c2c2c`, lower line `d4d4d4`, on a page of `181825`. Under Breeze Dark with the choice *Dark* it was `2c2c2c` and `d4d4d4`, on `2b3036`. The two agree. Under Breeze Light with the choice *Light* it was also `2c2c2c` and `d4d4d4`, on `eff0f1`: the rule does not tell a dark page from a light one. `CSI ? 996 n` in the terminal reads `CSI ? 997 ; 1 n`. The About panel (*About TarmacApp* in the app menu), captured by its window id: fill `313132`, luminance 0.031; its text `dfdfe0`, 0.738: dark. | pass (the rule cannot tell dark from light; the P0 canvas does) |
| **S67** One theme for both appearances | Launch H, a fresh channel, no `app-prefs.json`. `show "GitHub Dark"`, `apply Light on`, `apply Dark on` (each `value=1 enabled=1`, status 0). `rows`: `theme GitHub Dark marks=Light,Dark selected=1`, and `marks=` empty on each of the other seven rows; `box Apply to Light value=1 enabled=1`, `box Apply to Dark value=1 enabled=1`. File: `{"warn_before_quit":true,"theme_light":"github-dark","theme_dark":"github-dark"}`. `theme Auto`: `{"choice":"auto","in_effect":"dark","name":"github-dark"}`. `theme Light`: `{"choice":"light","in_effect":"dark","name":"github-dark"}`. `theme Dark`: `{"choice":"dark","in_effect":"dark","name":"github-dark"}`. After each press the five are `010409`, `161b22`, `0d1117`, `070a10`, `070a10`, and each of the three pictures is `010409` at its left point and at its right point. | pass |
| **S68** A relaunch with a dark theme saved for the light appearance | The Mac Light. File written while the app was down: `{"warn_before_quit":true,"theme":"light","theme_light":"catppuccin-mocha"}`. `make run`. First snapshot, 3.4 s after `make run` was started: `{"choice":"light","in_effect":"dark","name":"catppuccin-mocha"}`. The first capture, 0.6 s after that snapshot, shows the cards drawn, and holds no 4 × 4 flat area of the eight Breeze Dark fills nor of the eight Breeze Light fills (tolerance 0). Five: `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. Settings opened, `pane Theme`: fill `343637`, 0.036; label `e0e0e0`, 0.745: dark. The selected row is Catppuccin Mocha, with `marks=Light`; `tile Light value=1`. The file's SHA-1 is the same after the launch. | pass |
| **S69** A change of the Mac changes nothing under *Light* | The table *S49 and S69, step by step* below. With the two themes of S49 and the choice *Light*, the snapshot's `theme` was `{"choice":"light","in_effect":"dark","name":"catppuccin-mocha"}` before the Mac was set Dark, in every read of the 2 s after that, 2 s after it, in every read of the 2 s after the Mac was set Light, and 2 s after that. The five were those of Mocha, the file's SHA-1 was the same, and the Settings window was dark, each time. No read gave `solarized-light`. | pass |
| **S70** The script tells the two tables apart | The Settings window on *Theme*, Breeze Dark shown. `rows` prints `pane=Theme`. `pane "Breeze Dark"`: status 1, `the sidebar lists ["Fonts", "Theme"] and none is Breeze Dark`; `rows` still prints `pane=Theme`. `show Fonts` and `show Sepia`: status 1 each, `the list of themes holds [the eight titles] and none is Fonts` (and `Sepia`); the selected row is still Breeze Dark. `pane Fonts`: `rows` prints `pane=Fonts` and no `theme`, `showcase`, `picture`, `box` or `note` line (0 lines). `pane Theme`: `pane=Theme`, the eight `theme` lines, the `showcase`, `picture`, two `box` and `note` lines again. | pass |
| **S71** What keeps the shown theme, and what sets it | The choice *Dark*, Catppuccin Mocha applied to Dark. `show "GitHub Light"`: the selected row is GitHub Light, `showcase title=GitHub Light caption=light theme`. It is the same after `pane Fonts` and `pane Theme`; after `theme Auto` (the snapshot went to `{"choice":"auto","in_effect":"light","name":"breeze-light"}`) and `theme Dark`; after `apply Light on` (`marks=Light` on GitHub Light, file `…"theme_light":"github-light","theme_dark":"catppuccin-mocha"}`) and `apply Light off`. Then the Settings window was made the app's main window through Accessibility, with the dev app in front; `key 13`: the window list of the app holds the main window only. `open`: `pane=Theme`, the selected row is Catppuccin Mocha with `marks=Dark`, `showcase title=Catppuccin Mocha caption=dark theme`. The first try of `key 13` did not close the window: see *Found on the way*. | pass (the close was run two times) |

S65, theme by theme. The app is dark (Breeze Dark in effect). The three
points are the offsets of *What this run uses*.

| `show` | `rows`: selected row; `showcase` line | `note` line | Board, `bg0` | Terminal body, `terminal.background` | Doc page, `bg1` |
| --- | --- | --- | --- | --- | --- |
| Breeze Light | Breeze Light; `title=Breeze Light caption=light theme` | `Every terminal colour passes the contrast floors.` | `e3e5e7` | `fcfcfc` | `eff0f1` |
| Breeze Dark | Breeze Dark; `title=Breeze Dark caption=dark theme` | `5 terminal colours have low contrast on the background.` | `24282c` | `31363b` | `2b3036` |
| Catppuccin Latte | Catppuccin Latte; `title=Catppuccin Latte caption=light theme` | `9 terminal colours have low contrast on the background.` | `dce0e8` | `eff1f5` | `e6e9ef` |
| Catppuccin Mocha | Catppuccin Mocha; `title=Catppuccin Mocha caption=dark theme` | `2 terminal colours have low contrast on the background.` | `11111b` | `1e1e2e` | `181825` |
| GitHub Light | GitHub Light; `title=GitHub Light caption=light theme` | `Every terminal colour passes the contrast floors.` | `eaeef2` | `ffffff` | `f6f8fa` |
| GitHub Dark | GitHub Dark; `title=GitHub Dark caption=dark theme` | `1 terminal colour has low contrast on the background.` | `010409` | `0d1117` | `070a10` |
| Solarized Light | Solarized Light; `title=Solarized Light caption=light theme` | `8 terminal colours have low contrast on the background.` | `eee8d5` | `fdf6e3` | `f6efdc` |
| Solarized Dark | Solarized Dark; `title=Solarized Dark caption=dark theme` | `4 terminal colours have low contrast on the background.` | `001e26` | `002b36` | `00252e` |

Each value is the value of that theme's table in the spec, with a
difference of 0.

S49 and S69, step by step. Catppuccin Mocha is applied to Light and
Solarized Light to Dark. The Settings window is open on *Theme*, and its
selected row is Solarized Light in every step. *Mocha five* is `11111b`,
`313244`, `1e1e2e`, `181825`, `181825`. *Solarized five* is `eee8d5`,
`e5e1cf`, `fdf6e3`, `f6efdc`, `f6efdc`. The file under *Auto* is
`{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":14,"theme":"auto","theme_light":"catppuccin-mocha","theme_dark":"solarized-light"}`,
SHA-1 `1a8fc8c5…`. The time of a change is counted from the return of the
System Events call, which took 0.15 s.

| Step | The Mac | Snapshot's `theme` | Five | The Settings window | File, `rows` |
| --- | --- | --- | --- | --- | --- |
| S49, start | Light (`dark mode` `false`) | `{"choice":"auto","in_effect":"dark","name":"catppuccin-mocha"}` | Mocha five | fill `343637`, 0.036; label `e0e0e0`, 0.745: dark | `1a8fc8c5…`; `marks=Light` on Catppuccin Mocha, `marks=Dark` on Solarized Light, `tile Auto value=1` |
| S49, the Mac set Dark | Dark | `{"choice":"auto","in_effect":"light","name":"solarized-light"}`, 0.44 s after the change; the app runs on | Solarized five, 1 s later | fill `f7f7f7`, 0.930; label `262626`, 0.019: light | the same SHA-1; the same selected row and marks |
| S49, the Mac set Light, 2.6 s after it was set Dark | Light | `{"choice":"auto","in_effect":"dark","name":"catppuccin-mocha"}`, 0.87 s after the change; the app runs on | Mocha five | fill `343637`; label `e0e0e0`: dark | the same SHA-1; the same selected row and marks |
| S69, `theme Light` | Light | `{"choice":"light","in_effect":"dark","name":"catppuccin-mocha"}` | Mocha five | dark, the same two values | file now ends `"theme":"light","theme_light":"catppuccin-mocha","theme_dark":"solarized-light"}`, SHA-1 `4587ac0c…`; `tile Light value=1` |
| S69, the Mac set Dark | Dark | the same in every read of 2 s (a read each 0.1 s), and after them; the app runs on | Mocha five | dark, the same two values | `4587ac0c…`; the same selected row and marks |
| S69, the Mac set Light, 3.1 s after it was set Dark | Light | the same in every read of 2 s, and after them; the app runs on | Mocha five | dark, the same two values | `4587ac0c…`; the same selected row and marks |
| S49, `theme Auto` | Light | `{"choice":"auto","in_effect":"dark","name":"catppuccin-mocha"}` | not sampled | not sampled | `1a8fc8c5…` again |
| S49, the Mac set Dark | Dark | `solarized-light`, 0.56 s after the change | not sampled | not sampled | |
| S49, the app quit by pid and `make run` started, the Mac Dark (`dark mode` `true`) | Dark | first snapshot, 4.4 s after `make run` was started: `{"choice":"auto","in_effect":"light","name":"solarized-light"}` | the first capture, 0.75 s after that snapshot: status bar `f6efdc`, and no 4 × 4 flat area of a Breeze fill, dark or light. Then, with the window at its size: Solarized five | not opened | `1a8fc8c5…` |
| S49, the Mac set Light, 7.8 s after it was set Dark | Light | `{"choice":"auto","in_effect":"dark","name":"catppuccin-mocha"}`, 0.54 s after the change, in the new process; the app runs on | Mocha five | not opened | `1a8fc8c5…` |
| The end | Light: `dark mode` `false`, `AppleInterfaceStyle` has no value | | | | |

### Found on the way (revision 2)

- **A new doc card can show a white page for 1 or 2 frames.** S41. The page
  of a doc card that is made under a dark theme is the system's dark canvas
  (`1e1e1e`) for 3 to 8 frames. In some recordings the whole page was then
  white (`ffffff`) for 1 or 2 frames, before it was the theme's `bg1`. The
  header of the card has the theme's value in those frames. The counts:

  | Theme in effect | A file never opened before | A file opened again |
  | --- | --- | --- |
  | Catppuccin Mocha | 2 of 5 recordings have white frames (2 frames, 1 frame) | 0 of 6 |
  | Breeze Dark | 1 of 5 recordings has white frames (2 frames) | 0 of 4 |

  So the white frames are there under Breeze Dark too, and they were seen
  only at the first open of a file. They are not a Breeze fill, and they are
  not from the theme that was chosen. The run of revision 1 has two
  recordings of a first open, one under each theme, with no white frame: by
  these counts that does not show that they are new. `DocWebView.swift` has
  no change in the working tree. This run did not find the cause, and
  cannot say whether it is from this change. The Mac was Light and the app
  dark in every recording. A light Mac with a dark app is what the choice
  *Dark* gave before this change too.
- **A window was moved by the user during the run.** The Settings window
  was put on the second display for the recordings of S42 and S41, and the
  user moved it back to the main display after them. The two recordings were
  checked: the Settings window is in no frame of them. The frame reads of
  S33 were made again at the new place (its row has them). After that, each
  step that uses a place on the screen read the window list and the snapshot
  again.
- **The first `key 13` of S71 closed a terminal card.** The run made the
  Settings window key by a click at the HID tap, as the run of
  `theme-qa.md` did. The window of another app (the user's installed
  Tarmac) was over that point, so the click went to it and the dev app was
  no longer the active app. The ⌘W that `key 13` then posted to the dev app
  went to its main window, which closed the selected terminal card (the one
  with the lines of S37, which was done). The Settings window stayed open
  and showed GitHub Light still. The run then brought the dev app in front
  with `tarmac dev focus board` (which selects no card), made the Settings
  window the app's main window through Accessibility, and sent `key 13`
  again: the window closed. For a later run: check which app is in front and
  which window is key before `key 13`, and do not post a click at a point
  that another app's window covers. The later scenarios used the second
  terminal.
- **`apply Dark on` on the locked box says "is disabled".** S53, command 2.
  The box of Breeze Dark is on and disabled. The script tests "disabled"
  first, so its message is `the box Apply to Dark is disabled` and not
  `is already on`. The status and the last line are those the spec asks for.
- **The `picture frame=` line is 1 point larger on each side than the drawn
  image:** 362 × 226 for 360 × 224. The offsets of S65 are from the frame's
  origin.
- **The selected row is grey while the list does not have the keyboard.**
  When the window opens, and after `show`, the selected row of the list has
  the grey highlight of an inactive list. The sidebar's selected row is
  blue. No scenario asks for a colour here.
- **The rule of a doc is the same under a light and a dark page.** S66. Its
  two lines are `2c2c2c` and `d4d4d4` under Breeze Dark, under Breeze Light
  and under Catppuccin Mocha. `theme-qa.md` has the same values. So the
  rule is not a part that tells the page's `color-scheme`.
- **The fill of the Settings window differs with its place.** `2d2b2b` on
  the fresh channel, `343739` and `343637` later, under the same dark
  appearance. It is a material: the window was at another place, over
  another background.
- **A shell that ends with a failure leaves its card.** The toast of S36 was
  put up by `exit 3` in a new terminal. The card stayed on the board, drawn
  faint, over the cards under it, until it was closed with ⌘W. Not a matter
  of the theme.
- **A zoom changes a doc's scroll position by some pixels.** The
  `scroll.offset` of `theme-doc.md` was 660, then 659 after zoom 3 and back,
  then 652 after zoom 0.25 and 0.3 and back. S39 compares two reads with no
  zoom between them. Not a matter of the theme.
- **The first snapshot of a fresh channel can name a terminal that is then
  replaced.** In launch H the first snapshot came 2.7 s after `make run`
  started, before the daemon's socket was there, and its one terminal card
  had an id that the board did not have some seconds later. In launch B the
  first snapshot came later and its id stayed.
- **A stale lock of `pyenv` made a new shell wait 60 s.** After launch A was
  stopped (the daemon with `make kill-daemon`), `~/.pyenv/shims/.pyenv-shim`
  stayed, and the first shell of launch B printed
  `pyenv: cannot rehash: couldn't acquire lock` and had `proc` `bash` for
  about 70 s. `pyenv` removes a lock that is older than 2 minutes, and it
  did. The run removed nothing. Wait for `proc` `zsh`, with a timeout of
  90 s, before the first typed command.
- **The input source's indicator is a window of the app.** The window list
  of the dev app sometimes holds a third window, 84 × 77, at layer 3, near
  the caret of the focused terminal. A helper must find the main window by
  its title.
- For a later run:
  - A board point for the five fills must be 100 points or more from every
    card. The run of revision 1 has the reason. After a launch the cards
    are at other places in the window: compute the points from the
    snapshot.
  - To drag a card by its header at a zoom below 0.5, press three quarters
    of the way down the header. A press in its upper half takes the card's
    top edge and changes its height.
  - A card is culled at zoom 1 when it is more than one view width past the
    window's edge: drag it there at zoom 0.3.
  - The Settings window is 873 points wide. Beside a main window of 1830
    points it does not fit on a display of 2560 points. A capture by window
    id does not need it clear; a recording and a region capture do.

### Not covered (revision 2)

- The automatic change of the Mac's appearance at sunset, a bundled app,
  and a tooltip under the app's appearance (the spec's *Trade-offs and
  Limitations*).
- A Mac that starts Dark: S33, S55, S66 and S68 ran on a light Mac, as they
  ask.
- A build of `c6229ea` or of `f683657`: the frame of S33 and the `make qa`
  of S52 on them are from the earlier records.
- S36 under a theme other than Catppuccin Mocha. S43 has the five fills and
  the prime header for each of the eight.
- S41 and S42 under a light theme, and a far card brought into view by a
  pan.
- A row's swatch: no scenario samples it. In the captures each swatch shows
  its theme's board, card and bar.
- The host page's backdrop of an HTML card after a change: it is not on
  screen.
- A 2× display, and a display with another colour profile.
- `make qa` under a theme other than Breeze Dark.
