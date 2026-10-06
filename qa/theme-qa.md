# QA — the theme setting (#209, spec 2610.0007)

The live half of [spec 2610.0007](../.blueprint/specs/2610.0007_theme_setting.md):
its 33 `[QA]` scenarios, with the values observed. The unit scenarios are
`ThemeChoiceTests`, `AppPrefsTests`, `PaletteTests`, `ContrastTests`,
`ThemeCSSTests`, `DocTemplateTests`, `DevSnapshotTests`, `SettingsPaneTests`,
`TerminalViewTests`, `TerminalRendererTests` and `CardShimTests`.

It is also the §1.3 exception-1 and exception-2 discharge for the shell of
this change: `ThemeSettings`, `Theme`, `ThemeFollowing` and every view that
conforms to it, `SettingsWindowController` and the pane and tile files
(`SettingsSidebar`, `SettingsGroup`, `FontsPane`, `ThemePane`, `ThemeTile`),
the theme paths of `DocWebView` and `HTMLCardView`, `tarmacDoc.theme`,
`card-host.html`, `DevSnapshotReader`, and the launch order in `AppDelegate`.

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.

**Result:** 30 scenarios pass. 3 fail as they are worded: S39 (the app menu),
S50 (its last clause) and S65. Each is in *Found on the way*. No code was
changed.

**Run:** 2026-10-06, macOS 26.7 (25G229), a `make run` debug build of the
branch `feat/209-theme-setting-settings-window` on `6e54cda`. Main display:
BenQ EW2770QZ at 1×, with its own colour profile (`BenQ EW2770QZ`). The Mac's
appearance was Light and was not changed in this run. A fresh dev channel,
`.dev/qa209q`, removed after the run. S57 and S58 are the one exception: they
were run on `57153fc` (see their rows).

## The capture tolerance

Measured first, on a tree this change did not touch: `289d208`, built in a
worktree of its own with a fresh channel, one terminal and one doc card.

| Fill | Value in that tree | Sampled, 3 or 4 points each |
| --- | --- | --- |
| board | `24282c` (`Theme.bg0`) | `24282c` |
| doc card header | `353b41` (`Theme.bg2`) | `353b41` |
| terminal body | `31363b` (`Theme.termBg`) | `31363b` |
| status bar | `2b3036` (`Theme.bg1`) | `2b3036` |
| doc page | `2b3036` (`--bg1`) | `2b3036` |

The largest difference in a channel is 0, at 16 points. **The tolerance is 1.**
Each 7 × 7 square round a point held one colour.

## What it uses

- `tarmac dev snapshot`: `theme`, `fonts`, `viewport`, `focused_card`,
  `content_origin`, and each card's `screen_rect`, `scroll` and `term`.
- A capture is `screencapture -o -l <window id>` of a window of the app's
  pid, drawn into an sRGB bitmap and read there. A sample point is computed
  from `content_origin` and a card's `screen_rect`, never typed by hand. An
  open menu is captured by region (`screencapture -R`): a capture by window
  id shows a menu's material with nothing behind it, as a grey.
- The main window was made 1830 × 1250 through Accessibility, so that 13
  cards show at zoom 1.
- [`theme-doc.md`](theme-doc.md): a doc that scrolls, with a blockquote, a
  table, a rule, inline code, a code block and a link in its middle.
  [`theme-console.html`](theme-console.html): one console line of each level.
  [`html-card-scheme/`](html-card-scheme/README.md): the twelve probe pages.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift):
  `open`, `rows`, `pane`, `theme`, `pick`, `size`, `step`, `move`, `key`,
  `click`, `wheel`.
- [`scripts/qa/wheel-gesture.swift`](../scripts/qa/wheel-gesture.swift) pans
  the board and scrolls a selected card.
- **Accessibility reads what a capture cannot.** The static texts of the main
  window give the frame of each part of a doc page (S33), the random id each
  probe page shows (S63), and the frame of a header's console mark. An open
  console is a text area, and its value is the console's text (S62).
- A press, a drag and a double click are posted at the HID tap: to move a
  card by its header, to open a console, and to select a word of a doc.
- Scratch scripts in a terminal card: one sends the colour queries and logs
  the answers; one sets mode 2031 and logs every byte it reads, with a time;
  one sends `OSC 11` and later `OSC 111`.
- S65 is a 60 fps `ffmpeg` recording of the card's place on the screen.

## Checks

*Dark five* means: board `24282c`, doc card header `353b41`, terminal body
`31363b`, status bar `2b3036`, doc page `2b3036`. *Light five* means: board
`e3e5e7`, doc card header `dee0e2`, terminal body `fcfcfc`, status bar
`eff0f1`, doc page `eff0f1`. Each was sampled with a difference of 0, on a
doc card's header and on the body of the prime terminal.

### Launch, the window, the file

| Scenario | Observed | Result |
| --- | --- | --- |
| **S26** A fresh channel | No `app-prefs.json`. `theme` `{"choice":"dark","in_effect":"dark"}`. Dark five. Done on two fresh launches. | pass |
| **S27** The window | First ⌘,: `pane=Fonts`, three pop-ups on *System Default*, sizes 16 and 14. *Theme*: one label *Appearance*, tiles *Auto*, *Light*, *Dark* in that order, values 0, 0, 1; in the capture only *Dark* has the blue ring and the bold title. *Fonts* again: the three rows. Frame 691 × 299 for both panes. The size is not settable, no grow area, the zoom button is off, and a set of the size through Accessibility is refused (-25200). | pass |
| **S36** Relaunch on Light | Quit by pid, `make run`. First snapshot `{"choice":"light","in_effect":"light"}`; light five; the first capture of the window, 1.5 s after launch, holds no dark fill. ⌘,: `pane=Fonts`. *Theme*: values 0, 1, 0. | pass |
| **S38** Auto, on a light Mac | From *Dark*: *Auto* gives `{"choice":"auto","in_effect":"light"}`, the file ends `"theme":"auto"`, values 1, 0, 0, light five. After quit and launch: the same `theme` and light five. | pass |
| **S39** The system's parts | *Light*: Settings window fill `f7f7f7`, pop-up `f5f6f6`, app menu `edf1f3`; each text near black (`1d1d1d`, `222223`). *Dark*: Settings window `363638` with white text, pop-up `262729` with text `dfdfe0`. **The app menu under *Dark* is light: fill `bec1c4`, text `1c1d1d`.** Seen three times, once with the dev app checked to be in front by pid. | **fail** (the app menu, under *Dark* on a light Mac) |
| **S48** A press that changes nothing | *Light* pressed again: the file's modification time is the same to the nanosecond, same bytes. From *Auto*, *Light* pressed: the file ends `"theme":"light"`, `theme` `{"choice":"light","in_effect":"light"}`, 0 pixels of the whole window differ between the capture before and the one after, and the mode-2031 script logged nothing in the 2.7 s after the press (its line before is the *Auto* press, its next line is 213 s later). | pass |
| **S51** The font rows, under Light | `pick 0 Monaco`: `fonts.terminal` `{"face":"Monaco","saved":"Monaco","size":16}`. `step 0 up`: size 16.5. `size 1 17`: `fonts.document.size` 17. File: `{"warn_before_quit":true,"terminal_font":"Monaco","terminal_font_size":16.5,"document_font_size":17,"theme":"light"}`. | pass |
| **S52** Events over the window | Settings on *Theme*, in front of the main window, a point P of it over `theme-doc.md`; `fresh.md` selected. A click, a second click, a wheel and a Control wheel at P: `focused_card`, `cx` 994.920, `cy` 577.762, `zoom` 1 and the doc's `scroll.offset` 749 are the same after each. By chance the same four were first posted with the main window in front of the Settings window: there the click selected `theme-doc.md`, the wheel moved its offset 709 → 749, and the Control wheel took the zoom 1 → 0.67. | pass |
| **S53** The pane of the session | Settings made key by a click on its title bar, ⌘W: the window list holds the main window only. ⌘,: `pane=Theme`. | pass |
| **S55** A theme that is not one | File `{"warn_before_quit":true,"terminal_font":"Monaco","theme":"sepia"}` written while the app was down. `theme` `{"choice":"dark","in_effect":"dark"}`, `fonts.terminal.saved` `Monaco`, dark five, *Dark* is the selected tile. The file's SHA-1 is the same after launch, after both panes showed, and after *Dark* was pressed. | pass |
| **S56** The file cannot be saved | The channel directory made read-only with the app up. *Light*: light five, `theme` `{"choice":"light","in_effect":"light"}`, values 0, 1, 0, one new stderr line `tarmac: could not save app prefs: … Code=513 …`, the file's SHA-1 unchanged, the same two windows, the app runs on. | pass |

### A change of the theme

One board: five terminals, `theme-doc.md`, four probe pages, the console
probe, and one doc from each of two throwaway repositories. All set up under
the dark theme, then *Light* pressed once.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S28** Dark to Light | `theme` `{"choice":"light","in_effect":"light"}`; file `{"warn_before_quit":true,"theme":"light"}`; light five; values 0, 1, 0. Each tile's picture, 58 × 36 pixels 4 in from its edge: largest difference 0 between the two captures. Mean of the *Light* picture `dee4e4`, of the *Dark* one `323d40`. The *Auto* picture holds `31363b`, `24282c`, `353b41` and `fcfcfc`, `e3e5e7`, `dee0e2`. | pass |
| **S29** Each part | The table below. No capture of the main window under Light holds a 4 × 4 flat area of a dark-only fill (10 captures scanned). | pass |
| **S30** Text already drawn | No key in the terminal after the press. Full block `232629` (the dark capture has `ced2d6`). ANSI 2 background `0b8a0f`; the other fifteen backgrounds are the light column too. Body `fcfcfc`. Selected empty cell `b6d8d1`; `fcfcfc` with `12846e` at 0.3 computes `b6d8d1`. Grid 44 × 14 before and after. One pixel column in ten of the block row, where two cells meet, reads `25282b`: see *Found on the way*. | pass |
| **S31** The answers | `rgb:2323/2626/2929`, `rgb:fcfc/fcfc/fcfc`, `rgb:0b0b/8a8a/0f0f`, `CSI ? 997 ; 2 n`. | pass |
| **S32** Mode 2031 | The log after dark → light → dark: `mode 2031 set`, one `\x1b[?997;2n`, one `\x1b[?997;1n`. Over the whole run it holds one line for each later change made while the app ran, and no other byte. | pass |
| **S33** A doc keeps its place | Card made 392 × 500 so that all the parts show. `scroll.offset` 710 under light, dark, light. Page `eff0f1` / `2b3036`; code block `fcfcfc` / `31363b`; inline code `dee0e2` / `353b41`. Text of prose, blockquote and table `31363b` under light, `ced3d7` under dark; link `12846e`, `1abc9c`. The rule is two lines: `aeafb0` and `e6e7e8` under light, both darker than the page; `64676b` and `2c2f33` under dark, the first lighter than the page and the second close to it (the page is `2b3036`). The selected word's fill is `ccdfdc` under light and `284646` under dark. | pass |
| **S34** A doc opened under Light | The card is in the snapshot 0.07 s after `tarmac open`; the first capture, 0.47 s after it, has the page `eff0f1` at three points, with its text drawn. | pass |
| **S35** The HTML card | Header `353b41` under dark, `dee0e2` under light. Console fill `24272b` under dark (bg0 at 0.94 over the page's `1e1e1e` computes `24272b`) with text `b9bfc4`, `fdbc4b`, `f28b82`; `e5e7e8` under light (over `ffffff`: `e5e7e8`) with text `535d66`, `a36802`, `da4453`. | pass |
| **S37** Cards made under Light | A new terminal (⌘T): body `fcfcfc`, prime header `d0d4d8`. The doc of S34: page `eff0f1`. | pass |
| **S49** The repo dots | `repo-d` (palette entry 0) `f67400` → `be5a00`. `repo-c` (entry 1) `11d116` → `0b8a0f`. A doc of this repository (entry 3) `9b59b6` → `9b59b6`. | pass |
| **S50** A colour a program set | After the change every empty cell is `102030` (card made prime, so not dimmed). After `OSC 111` **only the row of the cursor is `fcfcfc`; the other rows stay `102030`** until they are drawn again. A resize of the card by 20 points made every empty cell `fcfcfc`. | **fail** (the last clause, as worded) |

S29, part by part. Every value is from a capture under the light theme.

| Part | Token | Light value | Sampled |
| --- | --- | --- | --- |
| Prime card's header | `primeHeaderBg` | `d0d4d8` | `d0d4d8` |
| Header, not prime (a doc card) | `bg2` | `dee0e2` | `dee0e2`; title text `535d66` |
| Border, not selected | `line` | `b4b9be` | `b4b9be` |
| Border, selected | `agent` at 0.5 over the card's fill `fcfcfc` | `87c0b5` | `87c0b5` |
| Status bar | `bg1`; rule `lineSoft` | `eff0f1`; `c9cdd1` | `eff0f1`; `c9cdd1`; text `707d8a` and `18693a` (`ok` is `176839`) |
| Zoom control | `bg2`; border `line`; rules `lineSoft` | `dee0e2`; `b4b9be`; `c9cdd1` | the same three; text `232629` |
| Minimap | `bg0` at 0.92 over the board; border `line`; view stroke `agent` | `e3e5e7`; `b4b9be`; `12846e` | the same three. View fill `c1d5d4` (`agent` at 0.16 computes `c2d5d4`); a card under it `afc4c5` (`bg3`, computes `afc5c5`); the prime card `359583` and the bell card `957c31`, each 1 from the computed blend |
| Provenance edge | `agent` at 0.7 | over the board there, `e0e2e4`: `50a091` | the fullest pixels of a dash: `509f90` to `52a093`. The line is 1.5 points wide, so most of its pixels are part covered |
| Toast, put up after the change | `bg2`; border `line` | `dee0e2`; `b4b9be` | `dee0e2`; `b4b9be`; title `232629` |
| Off-screen hint | `bg2` | `dee0e2` | `dee0e2`; text `535d66` (a running program), `232629` (a bell); borders `8dbbb4` and `c1a573`, each 1 from `agent` at 0.4 and `amber` at 0.5 over `bg2` |
| Switcher: query line and footer | `bg1`; rules `lineSoft` | `eff0f1`; `c9cdd1` | `eff0f1`; `c9cdd1`; text `707d8a`, caret `12846e` |
| Switcher: a row, the selected row | `bg2`, `bg3`; border `line` | `dee0e2`, `cdd1d5`; `b4b9be` | `dee0e2`, `cdd1d5`; `b4b9be`; names `232629` and `12846e` |
| Console of the HTML card | `bg0` at 0.94 over the page; rule `lineSoft` | `e5e7e8`; `c9cdd1` | `e5e7e8`; `c9cdd1`; log `535d66`, warning `a36802`, error `da4453` |
| Owner chip | border `lineSoft`; text `faint` | `c9cdd1`; `707d8a` | `c9cdd1`; `707d8a` |
| Repo dot | `repoColors` | `be5a00`, `0b8a0f`, `9b59b6` | the same three |
| Scroll thumb, a long doc | `scrollThumb`; `scrollThumbLine` | `181b1d`; `696b6c` | `181b1d`; `696b6c` |
| Scroll thumb, a terminal with scrollback | the same | `181b1d`; `696b6c` | `181b1d`; `696b6c` |

The switcher's veil is black in both themes, as the spec says.

### States, boards, cards not on screen

| Scenario | Observed | Result |
| --- | --- | --- |
| **S45** Two boards, a culled card | The active board: a terminal, a doc, a P0 card, and a P0 card 1981 points past the window's right edge. The cull margin is one viewport (1830 points), so that card is culled. The other board is not mounted. *Light*, then the first capture: terminal body `fcfcfc`, its prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff` with a `000000` block. `zoom 0.25` brings the far card in; the capture 0.47 s after: P0 `ffffff`, block `000000`, header `dee0e2`. The other board, in the capture 0.45 s after the switch was asked: terminal body `fcfcfc`, prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff`; no dark-only flat area. | pass |
| **S46** States set under Dark | All in one capture, 0.4 s after the press, with no change of a card. Bell dot `b08130`, 22 pixels: `a36802` under the 0.8 dim computes `b08130`. The glyph's strokes are thinner than a pixel; its strongest pixel `ba9656` is 0.79 of the way from the header's fill to `b08130`. Prime header `d0d4d8`. Selected border `87c0b5` (`12846e` at 0.5 over `fcfcfc`). Fresh ring `96a9a7`, `94a7a6`, `91a5a3`: with `12846e` at 0.16 taken out they are `afb0b2`, `adaeb1`, `a9abad`, greys that go on from the card's shadow beside the ring (`b6b7b9`, `b4b5b7`, `b1b3b4`). Exited card: body `f1f2f3` (`fcfcfc` under the 0.55 dim computes `f1f2f3`); border `d9dcde` (computes `dadcdf`). | pass |
| **S47** A toast and a hint on screen | Under dark both are `353b41`. In the capture 0.9 s later, after *Light*: toast `dee0e2` with title `232629`; the three hints `dee0e2` with text `535d66` and `232629`. | pass |

### System appearance

Run on `57153fc`, not on the final tree, so that the Mac's appearance was
changed one time only. `git diff 57153fc..HEAD` does not touch
`ThemeSettings.swift`, `ThemeFollowing.swift` or `AppController.swift`; it
changes one line of `AppDelegate.swift` (the Settings window is given the
theme) and one of `Theme.swift` (`srgb` is no longer private). The change was
made with System Events (`set dark mode`), not by hand in System Settings; it
is the same preference. The Mac was Light before and after.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S57** Dark does not follow | Mac to Dark: every snapshot in the 3 s after is `{"choice":"dark","in_effect":"dark"}`; dark five; the file's SHA-1 and modification time are the same. Mac back to Light: the same. | pass |
| **S58** Auto follows | Mac to Dark: `in_effect` is `dark` 0.94 s after the change was asked (0.54 s after the command came back), no restart; dark five. Mac to Light: `light` after 0.65 s; light five. The file is `{"warn_before_quit":true,"theme":"auto"}` each time. | pass |

### The whole

| Scenario | Observed | Result |
| --- | --- | --- |
| **S61** `make qa` | `289d208`, fresh board: 27 of 27, S21 skipped. This change, final tree, fresh board, default theme: 27 of 27, S21 skipped. The two lists of checks are the same, line for line. | pass |

### HTML cards

The twelve pages on one board at zoom 0.5. *Canvas* is a point of the empty
area, *block* the middle of the `currentColor` block.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S62** The table | Loaded under dark: P0, P1, P3, P7, P11 canvas `1e1e1e`, block `ffffff`; P2, P4, P5, P6, P10 canvas `ffffff`, block `000000`; every console line ends `matches=true`. After a live change to light: P0, P1, P2, P4, P5, P6, P10 `ffffff` / `000000`; P3, P7, P11 `1e1e1e` / `ffffff`; every console's last line ends `matches=false`. After a relaunch under light (a fresh load): the same pairs, one line each, `matches=false`. | pass |
| **S63** No reload | Ids at the start: P0 `aryiwqi2`, P1 `d0xpswfr`, P2 `rg8kp5qt`, P7 `mkynuekz`. Dark: P0, P1, P7 `1e1e1e` / `ffffff`, P2 `ffffff` / `000000`. Light: P0, P1, P2 `ffffff` / `000000`, P7 `1e1e1e` / `ffffff`. Dark again: as at the start. The four ids are the same in all three. | pass |
| **S64** A card not on screen | P0 past the cull margin under light; theme to dark; `zoom 0.25` 1 s later; the capture 0.43 s after: canvas `1e1e1e`, block `ffffff`, header `353b41`. And P0 opened under dark with `tarmac open` from a terminal that far away (the card lands 1981 points past the window's edge); brought in the same way: `1e1e1e`, `ffffff`. | pass |
| **S65** No white at open | 8 runs of 5.5 s, 5 on a board of 17 cards and 3 on a board with one terminal. At two points of the body with no text, every run: the board's colour, then the dark canvas for 3 or 4 frames, then **white for 1 frame (2 frames in 2 of the 8 runs)**, then the dark canvas to the last frame. In the recording's own colours: `202327` × 91 to 106, `1b1b1b` × 3 or 4, `ffffff` × 1 or 2, `1b1b1b` × 218 to 235. In the white frame the whole body is white, the block too. | **fail** (a third colour; the last frame is dark) |
| **S66** Half of the colours | P8: canvas `1e1e1e`, block `222222`. P9: canvas `ffffff`, block `ffffff`. | pass |

## Found on the way

- **S39: the app menu does not take the app's appearance.** With *Dark*
  chosen on a light Mac, the menu that opens from the menu bar is light
  (`bec1c4` with text `1c1d1d`), while the Settings window and the pop-up of
  a font row are dark. A throwaway AppKit program that only sets
  `NSApp.appearance` to dark has the same light menu on this Mac (macOS
  26.7), and a dark appearance set on its `NSMenu`s did not change it (that
  program was not in front; one run). So the menu-bar menu follows the Mac.
  `289d208` sets the same property, so it is most likely the same there; that
  tree was not measured. The other half (*Light* on a dark Mac) was not run:
  the Mac was Light.
- **S65: one white frame when an HTML card opens under the dark theme.** It
  is in 8 of 8 runs, with many cards and with one. The spec's measurement
  before the change saw none in 5 runs. The frame of the card is white in
  `card-host.html` while it holds no document, which is what the spec keeps
  and what #213 is about; that this is the cause is inferred, not measured.
  The host page's own backdrop (`2b3036`) is in no frame of the recordings.
- **S50: a colour set with `OSC 11` or `OSC 111` reaches only the rows that
  are drawn again.** Under the dark theme, before any change of the theme,
  `OSC 11 ; rgb:10/20/30` alone turned only the cursor's row `102030`. The
  change of the theme then drew every row in `102030`, which is right.
  `OSC 111` alone again turned one row. `FrameReader.swift` reads only the
  rows the engine reports dirty, and it is not changed since `289d208`. A
  program that redraws after it sets a colour does not show this.
- **A program that set mode 2031 gets no report across a relaunch.** Seen
  once: the app was quit under light, the file was edited by hand, the app
  came up dark, and the script's log holds no line for it. In normal use it
  needs *Auto* and a change of the Mac's appearance while the app is down.
  Not a scenario.
- **S30: a seam in a row of full blocks.** Under light, the pixel column
  where two block cells meet reads `25282b`, 2 from `232629`; under dark the
  row is one colour. 1728 of 1920 pixels of the row are `232629`. The block
  is a glyph, and its edge is drawn with partial cover.
- **A card off the window is not a culled card.** The margin is one viewport
  on each side (`Cull.marginViewports`). S45 and S64 put the card 1981 points
  past the edge of an 1830-point window, and `zoom 0.25` brings it in.
- For a later run:
  - A key posted to the pid goes to the key window. ⌘W meant for the
    Settings window closed the selected card, because `tarmac dev focus` had
    made the main window key. Click the Settings window first.
  - `tarmac dev focus` puts the main window in front of the Settings window.
    Bring the Settings window forward again with ⌘, before S52.
  - After the dev app is quit and launched again, another app can be in
    front. A click posted at the menu bar then opens that app's menu. Check
    the frontmost pid before a posted click that is not on the dev window.
  - Name the `ffmpeg` screen device (`Capture screen 0`), not its number: the
    number moved when an iPhone camera came into range, and the recorder
    then opened the camera and did not end.
  - A header drag at zoom 0.25 takes the resize handle. Drag at 0.5.

## Regression: `make qa`

| Build | Board | Result |
| --- | --- | --- |
| `289d208`, in a worktree of its own | fresh, one doc card | 27 of 27, S21 skipped |
| this change, `6e54cda` | fresh, one doc card, default theme | 27 of 27, S21 skipped |

Both ran before the Settings window was shown in that process.

## Not covered

- A Mac whose appearance is Dark: the dark halves of S38, S39 and S48.
- S57 and S58 on the final tree (see *System appearance*).
- A 2× display, and a display with another colour profile.
- The app menu and the white frame on `289d208`: the tree was built for the
  tolerance and for `make qa` only.
- `make qa` under the light theme.
