# QA — the theme setting (#209, spec 2610.0007)

The live half of [spec 2610.0007](../.blueprint/specs/2610.0007_theme_setting.md):
its 33 `[QA]` scenarios, with the values observed. The unit scenarios are
`ThemeChoiceTests`, `AppPrefsTests`, `PaletteTests`, `ContrastTests`,
`ThemeCSSTests`, `DocTemplateTests`, `DevSnapshotTests`, `SettingsPaneTests`,
`TerminalViewTests`, `TerminalFrameTests`, `TerminalEngineTests` and
`CardShimTests`. The tests of the cards fix are in `CardHostScriptTests`,
`CardConsoleTests`, `HTMLCardSessionTests` and `CardShimTests`.

It is also the §1.3 exception-1 and exception-2 discharge for the shell of
this change: `ThemeSettings`, `Theme`, `ThemeFollowing` and every view that
conforms to it, `SettingsWindowController` and the pane and tile files
(`SettingsSidebar`, `SettingsGroup`, `FontsPane`, `ThemePane`, `ThemeTile`),
the theme paths of `DocWebView` and `HTMLCardView`, `tarmacDoc.theme`,
`card-host.html`, `DevSnapshotReader`, and the launch order in `AppDelegate`.

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.

**Result:** 30 scenarios pass as they were worded at the gate. 3 did not: S33
(one line of the rule), S39 (the app menu) and S65 (a third colour, the
card's own `bg1`; no white frame). Each is in *Found on the way*. The spec
was then changed for those three (its *Changed after the gate*): S33 asks
for one line of the rule that differs from the page in each theme, S39 no
longer holds the menu of the menu
bar to a value, and S65 allows `bg1` between the board and the document. The
values below pass all three as changed.

The first run changed no code and had 3 failures: S39, S50 (its last clause)
and S65 (a white frame). Two fixes followed, and a second run of S50, S62,
S63, S65 and S66: see **Second run**.

**Run:** 2026-10-06, macOS 26.7 (25G229), a `make run` debug build of the
branch `feat/209-theme-setting-settings-window` on `6e54cda`. Main display:
BenQ EW2770QZ at 1×, with its own colour profile (`BenQ EW2770QZ`). The Mac's
appearance was Light and was not changed in this run. A fresh dev channel,
`.dev/qa209q`, removed after the run. S57 and S58 are the one exception: they
were run on `57153fc` (see their rows).

**Second run:** the same day and machine, a fresh dev channel `.dev/qa209f`,
removed after the run. S50 on `ab71600` (the terminal fix). S62, S63, S65,
S66, *No card stays out of sight* and `make qa` on the cards fix: the commit
that carries this record, whose parent is `ab71600`. The rows say which run a
value is from.

**Third run:** the same day and machine, a fresh dev channel `.dev/qa209r`,
removed after the run, on `9ffd2e8` (the commit before the one that carries
this pass of the record). S31 with the cursor, the rule of S33, S45, the
fresh ring of S46, and S64. S31, S45, S46's ring and S64 pass. The rule of
S33 fails as it was worded at the gate: under dark its upper line is not
lighter than the page (its row has the values); it passes as changed. The Mac's appearance was Light and was
not changed.

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
- S65 is a 60 fps `ffmpeg` recording of the card's place on the screen. The
  second run records the whole main window (the screen device by its name,
  `Capture screen 0`) and reads the card's place from the snapshot afterwards.
- The third run records each step of S45 and S64 in the same way, and makes
  two captures in each: one at once, and one 1 s after the step was asked.
  Its colour script sends `OSC 12 ; ?` too. Its far cards are opened from a
  terminal that was moved far to the right: a doc lands beside the terminal
  that opened it.

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
| **S39** The system's parts | *Light*: Settings window fill `f7f7f7`, pop-up `f5f6f6`, app menu `edf1f3`; each text near black (`1d1d1d`, `222223`). *Dark*: Settings window `363638` with white text, pop-up `262729` with text `dfdfe0`. **The app menu under *Dark* is light: fill `bec1c4`, text `1c1d1d`.** Seen three times, once with the dev app checked to be in front by pid. | **fail** as worded at the gate (the app menu, under *Dark* on a light Mac); pass as changed |
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
| **S31** The answers | `rgb:2323/2626/2929`, `rgb:fcfc/fcfc/fcfc`, `rgb:0b0b/8a8a/0f0f`, `CSI ? 997 ; 2 n`. Third run, `9ffd2e8`, with `OSC 12 ; ?` (the cursor) sent after `OSC 11 ; ?`. Under light: `rgb:2323/2626/2929`, `rgb:fcfc/fcfc/fcfc`, cursor `rgb:2323/2626/2929`, `rgb:0b0b/8a8a/0f0f`, `CSI ? 997 ; 2 n`. Under dark: `rgb:cece/d2d2/d6d6`, `rgb:3131/3636/3b3b`, cursor `rgb:efef/f0f0/f1f1`, `rgb:1111/d1d1/1616`, `CSI ? 997 ; 1 n`. | pass (both runs) |
| **S32** Mode 2031 | The log after dark → light → dark: `mode 2031 set`, one `\x1b[?997;2n`, one `\x1b[?997;1n`. Over the whole run it holds one line for each later change made while the app ran, and no other byte. | pass |
| **S33** A doc keeps its place | Card made 392 × 500 so that all the parts show. `scroll.offset` 710 under light, dark, light. Page `eff0f1` / `2b3036`; code block `fcfcfc` / `31363b`; inline code `dee0e2` / `353b41`. Text of prose, blockquote and table `31363b` under light, `ced3d7` under dark; link `12846e`, `1abc9c`. The selected word's fill is `ccdfdc` under light and `284646` under dark. **The rule,** third run, `9ffd2e8`: it is two lines, one on the other, with the page above and below them. Each line is one third of a point thick, so at zoom 3 each is one row of pixels, and there the two lines have the same values under the two themes: the upper line `2c2c2c`, the lower line `d4d4d4`. The page beside them is `2b3036` under dark and `eff0f1` under light. So under light the two lines are darker than the page. Under dark the lower line is lighter than the page, and the upper line is not: it is a little darker (luminance 0.025; the page 0.029). At zoom 1 each line is one row of pixels at one third of its strength over the page: `2c2f33` (upper) and `64676b` (lower) under dark, `aeafb0` and `e6e7e8` under light, as in the first run. At zoom 2, two thirds: `2b2d2f` and `9b9d9f` under dark, `6d6d6d` and `dddddd` under light. In this run `scroll.offset` was 591 before and after a change from light to dark. | pass for every part but the rule. The rule: **fail** as worded at the gate for its upper line under dark, which is not lighter than the page; pass as changed (one line differs from the page in each theme). See *Found on the way* |
| **S34** A doc opened under Light | The card is in the snapshot 0.07 s after `tarmac open`; the first capture, 0.47 s after it, has the page `eff0f1` at three points, with its text drawn. | pass |
| **S35** The HTML card | Header `353b41` under dark, `dee0e2` under light. Console fill `24272b` under dark (bg0 at 0.94 over the page's `1e1e1e` computes `24272b`) with text `b9bfc4`, `fdbc4b`, `f28b82`; `e5e7e8` under light (over `ffffff`: `e5e7e8`) with text `535d66`, `a36802`, `da4453`. | pass |
| **S37** Cards made under Light | A new terminal (⌘T): body `fcfcfc`, prime header `d0d4d8`. The doc of S34: page `eff0f1`. | pass |
| **S49** The repo dots | `repo-d` (palette entry 0) `f67400` → `be5a00`. `repo-c` (entry 1) `11d116` → `0b8a0f`. A doc of this repository (entry 3) `9b59b6` → `9b59b6`. | pass |
| **S50** A colour a program set | First run, `6e54cda`: after the change every empty cell was `102030`; after `OSC 111` only the row of the cursor was `fcfcfc`, and the other rows stayed `102030` until they were drawn again. Second run, `ab71600`: a new terminal, prime, 44 × 14. Six rows sampled, three points each, right of any text; rows 8, 10, 12 and 13 are rows the shell never wrote to. Dark, before: all `31363b`. Dark, after `OSC 11 ; rgb:10/20/30`: all 18 points `102030`, and `102030` is the most frequent colour of the body. After the change to light: all `102030`. After `OSC 111`: all `fcfcfc`. | pass (`ab71600`; failed on `6e54cda`) |

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
| **S45** Two boards, a culled card | The active board: a terminal, a doc, a P0 card, and a P0 card 1981 points past the window's right edge. The cull margin is one viewport (1830 points), so that card is culled. The other board is not mounted. *Light*, then the first capture: terminal body `fcfcfc`, its prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff` with a `000000` block. `zoom 0.25` brings the far card in; the capture 0.47 s after: P0 `ffffff`, block `000000`, header `dee0e2`. The other board, in the capture 0.45 s after the switch was asked: terminal body `fcfcfc`, prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff`; no dark-only flat area. (That was the first run, `6e54cda`.) **Third run, `9ffd2e8`.** Board 1: the prime terminal, `theme-doc.md` and a P0 card in the window; a second terminal and two P0 cards far to the right, the two cards 1851 and 2329 points past the window's right edge. The first far card showed its page under dark at zoom 0.25 and was culled after that. The second was opened while it was culled and was never on screen. `tarmac dev focus` answers `card_hidden` for both. Board 2 (a terminal, a doc, a P0 card) was not shown from before the press. *Light*; the first capture, done 0.13 s after the press came back: terminal body `fcfcfc`, prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff` with a `000000` block and header `dee0e2`; no dark-only flat area. `zoom 0.25`; the first capture, done 0.34 s after it was asked: each far P0 card `ffffff` with a `000000` block and header `dee0e2`. The far terminal is not prime: body `f7f7f8`, header `dfe1e3` (`fcfcfc` and `dee0e2` under the 0.8 dim over the board compute the same two). Board 2, in the first capture, done 0.37 s after the switch was asked: terminal body `fcfcfc`, prime header `d0d4d8`, doc header `dee0e2`, doc page `eff0f1`, P0 `ffffff` with a `000000` block. The capture 1 s after each step has the same values, so no HTML card is at `bg1` then. In the 60 fps recordings: the first far card has its page in the frame in which the card shows; the second shows `bg1` for 1 frame (17 ms) and then its page; the P0 card of board 2 is white from the frame in which the card shows, and its text and its block come 2 frames (33 ms) later. | pass (both runs) |
| **S46** States set under Dark | All in one capture, 0.4 s after the press, with no change of a card. Bell dot `b08130`, 22 pixels: `a36802` under the 0.8 dim computes `b08130`. The glyph's strokes are thinner than a pixel; its strongest pixel `ba9656` is 0.79 of the way from the header's fill to `b08130`. Prime header `d0d4d8`. Selected border `87c0b5` (`12846e` at 0.5 over `fcfcfc`). Fresh ring, third run, `9ffd2e8`, in the first capture after *Light*, on a doc card and a P0 card that were opened under dark. The ring is 3 pixels wide. Its pixels beside the left border, from the outside in: `96a9a7`, `94a7a6`, `91a5a3` (the first run's values). Above the top border: `788b8a`, `778a88`, `758886`. Below the bottom border: `b1c5c3`, `b1c4c3`, `afc2c1`. Then Escape took the fresh mark off and nothing else changed. The same pixels, which are the board under the card's shadow: `b0b2b3`, `aeafb1`, `acadaf`; `8d8e8f`, `8b8c8d`, `898a8b`; `d0d2d4`, `ced0d2`, `cecfd1`. `12846e` at 0.16 over those computes `97aba8`, `95a8a6`, `93a6a5`; `798c8a`, `788b88`, `768986`; `b2c6c4`, `b0c4c2`, `b0c3c1`. So the ring is 1 from the blend at the top and at the bottom, and 1 or 2 at the left and at the right (the right is the same as the left). The pixels outside the ring are also 0 or 1 lighter with the ring off (`bbbdbe` goes to `bcbdbf`): the shadow there is a little weaker without the ring. Exited card: body `f1f2f3` (`fcfcfc` under the 0.55 dim computes `f1f2f3`); border `d9dcde` (computes `dadcdf`). | pass |
| **S47** A toast and a hint on screen | Under dark both are `353b41`. In the capture 0.9 s later, after *Light*: toast `dee0e2` with title `232629`; the three hints `dee0e2` with text `535d66` and `232629`. | pass |

### System appearance

Run on `57153fc`, not on the final tree, so that the Mac's appearance was
changed one time only. `git diff 57153fc..9ffd2e8 --stat -- app/Sources/TarmacApp`
names 12 files, 542 lines added and 154 removed. `ThemeSettings.swift`,
`ThemeFollowing.swift` and `AppController.swift` are not among them: they
are not changed. One line of `AppDelegate.swift` changes (the Settings
window is given the theme) and one of `Theme.swift` (`srgb` is no longer
private). The other ten are the Settings window (`SettingsWindowController`,
`SettingsSidebar`, `SettingsGroup`, `FontsPane`, `ThemePane`, `ThemeTile`)
and the HTML card of the cards fix (`HTMLCardView`, `card-host.html`,
`card-host.js`, `card_shim.js`). The change of the appearance was made with
System Events (`set dark mode`), not by hand in System Settings; it is the
same preference. The Mac was Light before and after.

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
| **S62** The table | Loaded under dark: P0, P1, P3, P7, P11 canvas `1e1e1e`, block `ffffff`; P2, P4, P5, P6, P10 canvas `ffffff`, block `000000`; every console line ends `matches=true`. After a live change to light: P0, P1, P2, P4, P5, P6, P10 `ffffff` / `000000`; P3, P7, P11 `1e1e1e` / `ffffff`; every console's last line ends `matches=false`. After a relaunch under light (a fresh load): the same pairs, one line each, `matches=false`. Second run, at zoom 0.25: the same pairs in all three states, with no mismatch in 30 pages; `matches=true` under dark, `matches=false` after the live change and after the relaunch (one line each there). | pass (both runs) |
| **S63** No reload | Ids at the start: P0 `aryiwqi2`, P1 `d0xpswfr`, P2 `rg8kp5qt`, P7 `mkynuekz`. Dark: P0, P1, P7 `1e1e1e` / `ffffff`, P2 `ffffff` / `000000`. Light: P0, P1, P2 `ffffff` / `000000`, P7 `1e1e1e` / `ffffff`. Dark again: as at the start. The four ids are the same in all three. Second run: P0 `ccd6pn7y`, P1 `n5sx1dkt`, P2 `n6kyysij`, P7 `a465p6th`, the same under dark, light and dark again, with the same pairs; the ids of the other eight pages did not change either. | pass (both runs) |
| **S64** A card not on screen | P0 past the cull margin under light; theme to dark; `zoom 0.25` 1 s later; the capture 0.43 s after: canvas `1e1e1e`, block `ffffff`, header `353b41`. And P0 opened under dark with `tarmac open` from a terminal that far away (the card lands 1981 points past the window's edge); brought in the same way: `1e1e1e`, `ffffff`. (That was the first run, `6e54cda`.) **Third run, `9ffd2e8`.** The two far P0 cards of S45, culled under light after each had shown its light page (`card_hidden` for both); theme to dark; `zoom 0.25` 3.6 s later; the first capture, done 0.40 s after the zoom was asked: canvas `1e1e1e`, block `ffffff`, header `353b41`, for both. In the recording each card has the dark canvas in the frame in which it shows. And a third P0 opened under dark with `tarmac open` from the far terminal while its place was 2297 points past the window's right edge (`card_hidden`); `zoom 0.25` 3.8 s later; the first capture, done 0.36 s after: canvas `1e1e1e`, block `ffffff`. In the recording it shows `bg1` for 2 frames (33 ms) and then the dark canvas. The captures 1 s after are the same. No frame of the two recordings is white or light at a canvas point. | pass (both runs) |
| **S65** No white at open | First run, `6e54cda`: 8 runs of 5.5 s, 5 on a board of 17 cards and 3 on a board with one terminal. At two points of the body with no text, every run: the board's colour, then the dark canvas for 3 or 4 frames, then **white for 1 frame (2 frames in 2 of the 8 runs)**, then the dark canvas to the last frame. In the recording's own colours: `202327` × 91 to 106, `1b1b1b` × 3 or 4, `ffffff` × 1 or 2, `1b1b1b` × 218 to 235. In the white frame the whole body is white, the block too. Second run, the cards fix: 10 runs of 5.5 s on a board with one terminal. At the same two points, every run: `202327` × 97 to 101, then **`262a2f` × 3 to 13** (5 or 6 frames in 7 of the 10), then `1b1b1b` × 217 to 228 to the last frame. `262a2f` is `bg1`: the status bar reads it in every frame of the same recordings. No frame is white at those points. The 3 or 4 dark frames of the first run are gone with the white: they were the web view before its page was drawn, and had the dark canvas's colour by chance. | **fail** as worded at the gate (three colours: the card's own `bg1` is between the two); pass as changed. No white frame; the last frame is the dark canvas. |
| **S65**, the other pairs | Light theme, P3 (states `dark`), 5 runs at zoom 0.25: the board `dfe1e4`, then `edeeef` × 5 to 7 (`bg1`, the status bar's value there), then `1b1b1b` to the last frame; no white before the dark page. Dark theme, P2 (states `light`), 3 runs: `202327`, then `262a2f` × 5, then `ffffff` to the last frame: the card goes from `bg1` to white one time. | no white before a dark page |
| **S66** Half of the colours | P8: canvas `1e1e1e`, block `222222`. P9: canvas `ffffff`, block `ffffff`. Second run: the same four values. | pass (both runs) |

### No card stays out of sight

The cards fix keeps an HTML card's web view out of sight until its document
is on screen. Each row is a way the word for that could fail to come. Second
run, dark theme unless the row says another.

| Case | Observed |
| --- | --- |
| A path with no file | `tarmac open` refuses it (`No such file or directory`): no card is made. |
| A file that cannot be read | A card's file made mode 000 and given a new change time: `bg1` × 3, then the served text (`…/reload.html: Permission denied (os error 13)`) on the dark canvas. Readable again: `bg1` × 2, then the page. This body carries no shim; the frame's `load` shows it. |
| The file changes | 3 rewrites, 1.2 s apart: each time the page, then `bg1` × 3 or 4, then the page with a new id. |
| A card born culled | The sixth of seven P0 cards opened in a row, 4104 points from the window's left edge at zoom 1 (the cull margin ends at 3660). `zoom 0.25`: `bg1` for 1 frame at its place, then the page. |
| A relaunch | 17 HTML cards on the board, light theme: every one shows its page in the first capture (the 12 of S62 are the check). |
| A page of 6.7 MB | Board, then `bg1` × 38, then the page: no white. |
| A page that stops its own load (`window.stop()` in a script) | The page shows. The frame's `load` never fires for it: the shim's message is what shows it. |
| The console | `theme-console.html`: its three lines and no other; no line for the two new messages. |
| A borrowed card | Double click (the driver's `focus`): `borrowed` is true and the keyboard focus is the frame. A key posted to the app reaches the page (`key k`, and the console line `[keys] keydown k`). Escape gives the keyboard back to the terminal. |

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
- **S65: one white frame when an HTML card opens under the dark theme.
  Fixed; what shows before the page is now `bg1`.** On `6e54cda` it is in 8
  of 8 runs, with many cards and with one. The first run inferred that the
  white was the card's frame (`#card { background: #fff }`) while it held no
  document. Measured in the second run, with that fill made magenta for the
  measurement, the white has two sources:
  - **The web view before its host page is first drawn.** The host page
    states no colour scheme, so for 1 or 2 frames the web view is white. With
    the frame hidden until the shim's first message (what #213 tried), 5 of 5
    opens still had 1 or 2 white frames. With the fill magenta, 2 of 3 did,
    and those frames were white, not magenta.
  - **The frame with no document in it.** With the frame not hidden, 2 of 3
    opens had 2 magenta frames.

  So hiding the frame cannot remove the white. Now the app keeps the whole
  web view out of sight until the host page says that the document is on
  screen, and the card shows its own `bg1` until then. The host page says it
  two of its own frames after the document started. Measured: said at once, 4
  opens of 5 still had one white or magenta frame; one frame later, 2 of 5;
  two frames later, none of 15.
  - A web view that draws no background of its own was tried too. It removes
    the white and breaks S62: P0 under dark then has the frame's colour, not
    the dark canvas.
  - The shim's message and the frame's `load` event come 1 ms apart for P0
    (the `load` first) and 17 ms apart for a page of 6.7 MB (the message
    first, 530 ms after the page was asked for). Both are needed: what is
    served for a file that cannot be read has no shim, and a page that stops
    its own load never fires `load` (with `load` alone its card stayed at
    `bg1` to the end of the recording).
  - S65 still fails as it is worded: `bg1` is a third colour. It is what #213
    expects of a card with no document yet.
  - A change of the file now shows `bg1` for 3 or 4 frames where it showed
    the white frame for 1 or 2. For a light page under the dark theme that is
    a dark blink where the white one could not be seen.
- **S50: a colour set with `OSC 11` or `OSC 111` reaches only the rows that
  are drawn again. Fixed in `ab71600`.** Under the dark theme, before any
  change of the theme, `OSC 11 ; rgb:10/20/30` alone turned only the cursor's
  row `102030`. The change of the theme then drew every row in `102030`, which
  is right. `OSC 111` alone again turned one row. A default colour changes no
  row, so the engine reports no row dirty (measured: 0 of 20), and
  `TerminalView` drew again only the dirty rows; the cursor's row came from
  the blink. `OSC 10` and `OSC 110` had the same defect for text with no
  colour of its own. Now a frame whose default background or foreground is
  not the one on screen draws every row. The suite's S44 test could not see
  it: its `drawn()` draws every row, whatever the view asked for.
- **S33: the rule has the same two greys under the two themes.** The
  template does not style `<hr>`, and the engine draws its border as two
  lines, `2c2c2c` on `d4d4d4`, whatever the theme. Under dark the upper line
  is at the page's own lightness and cannot be told from the page; the lower
  line is what shows. Each line is one third of a point thick at every zoom,
  so below zoom 3 a capture has a mix of the line and the page. Not changed.
- **A card that comes back with its board is blank for 2 frames.** Third
  run. When a board is shown again, an HTML card whose theme changed while
  the board was away shows its canvas with no text and no block for 2
  frames: white under light, the dark canvas under dark (one switch under
  each). It is the canvas of the theme in effect each time, never `bg1` and
  never the other theme's canvas. A switch back to a board with no change of
  the theme between had no such frame (one switch).
- **One frame without the block, 9 frames after a zoom.** Third run. In two
  of the three recordings of `zoom 0.25` from zoom 1 (S45, and the first
  half of S64), each of the three P0 cards shows, for one frame, the
  canvas's colour at the block's point, 9 frames (0.15 s) after the zoom.
  In the third recording the two cards that were read do not. The canvas's
  colour is the theme's own, so it is no white frame under dark. It was not
  looked for on `289d208`.
- **A doc's `scroll.offset` moves with the zoom, not with the theme.** Third
  run: 600, then 595 and 591 after zooms to 3 and to 0.25 and back to 1; 591
  before and after a change of the theme. S33 compares offsets with no zoom
  between them.
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
  - While a terminal has the keyboard, the app has one more small window
    (the input source's mark, 84 × 77). A capture by window id holds it, and
    is wider when the mark is past the main window's edge: the third run
    had captures 1836 wide, with every point 6 pixels to the right. Read
    the window list at each capture and take the main window's part.
  - A tool that sets the main window's frame through Accessibility must
    choose it by its title: the mark's window can be first in the list.

## Regression: `make qa`

| Build | Board | Result |
| --- | --- | --- |
| `289d208`, in a worktree of its own | fresh, one doc card | 27 of 27, S21 skipped |
| this change, `6e54cda` | fresh, one doc card, default theme | 27 of 27, S21 skipped |
| the cards fix, on `ab71600` | fresh, default theme | 27 of 27, S21 skipped; the same list of checks, line for line |

Each ran before the Settings window was shown in that process.

## Not covered

- A Mac whose appearance is Dark: the dark halves of S38 (*Auto* on a dark
  Mac), S39 (*Light* on a dark Mac) and S48 (the tile that names the Mac's
  appearance is *Dark*, and the file holds no `theme` member).
- S57 and S58 on the final tree (see *System appearance*).
- On `9ffd2e8`: every row but S31, the rule of S33, S45, the ring of S46
  and S64. `make qa` was not run on it. `9ffd2e8` changes the terminal's
  theme setter for an engine that refuses a theme, one constant of
  `Contrast`, where the rule of a tile's picture is, and comments.
- A terminal engine that refuses a theme. No way was found to make it
  refuse one, in a test or in the app.
- A far card brought into view by a pan. S45 and S64 use `zoom`, which
  shows the card in one step; a pan shows it while it is still out of the
  window.
- An HTML card that is culled on a board that is not shown, and the cards
  of S45 and S64 on a board that was never shown in that launch.
- The blank frames of a board that is shown again, under dark, for a page
  that states `light` (it would be white, which is right for it).
- A 2× display, and a display with another colour profile.
- The app menu and the white frame on `289d208`: the tree was built for the
  tolerance and for `make qa` only.
- A web content process that dies while a card is up. The card then loads
  its host page again, as a new card does; this was not run.
- Two changes of a file a few milliseconds apart. The host page drops the
  word for a source that was replaced; a word already on its way to the app
  is not told apart from the new one's, and neither is a start that the
  replaced page had posted and the host page had not yet heard.
- `make qa` under the light theme.
