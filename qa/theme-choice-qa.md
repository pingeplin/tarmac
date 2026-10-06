# QA — the theme choice (#217, spec 2610.0008)

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
  `move`, `menu`.
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
