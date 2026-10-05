# QA — the font Settings window (#204, spec 2610.0005)

The live half of [spec 2610.0005](../.blueprint/specs/2610.0005_font_settings_page.md):
its `[QA]` scenarios, with the values observed. The unit scenarios are
`AppPrefsTests`, `FontRoleTests`, `FontMenuTests`, `FontCSSTests`,
`TerminalFontsTests`, `TerminalViewTests` and `DevSnapshotTests`.

It is also the §1.3 exception-1 and exception-2 discharge for the shell the
change adds or touches: `SettingsWindowController`, `InstalledFonts`,
`FontSettings`, `AppPrefsStore`, `WarnBeforeQuit`, `Theme.mono`, the
`FontFollowing` broadcast and its conformers, `DocWebView.fontsChanged`,
`tarmacDoc.fonts`, the event-window guards in `AppController+Keys.swift` and
`AppController+Focus.swift`, the launch order in `AppDelegate`, the menu
item, the snapshot reader, and `DevInput.takeKey`.

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.

**Run:** 2026-10-05, macOS 26.7, a `make run` debug build of the branch
`feat/204-settings-page-fonts` (on `44e0c7e`), main display at 1×. Board
`board-1` of the dev channel, with two terminal cards (600 × 400 and
470 × 330), markdown and HTML fixture cards, and the prose fixture below.

## What it uses

- `tarmac dev snapshot`'s `fonts` object, and `cards[].term.cols` / `rows`,
  `cards[].scroll.total`, `focused_card`, `viewport`.
- [`font-settings-prose.md`](font-settings-prose.md): twenty paragraphs of
  several lines and one code block, opened with `tarmac open` from a dev
  terminal.
- **The pop-ups are operated through the Accessibility API**, with no
  pointer: [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift)
  presses the `AXPopUpButton` of a row, then the `AXMenuItem` with the wanted
  title (`pick`). It also reads each row's selected title and the window's
  labels (`rows`), chooses an item of the app menu (`menu`), moves the
  Settings window (`move`), and posts a click or a wheel at a screen point
  (`click`, `wheel`). This answers the spec's open question: no `tarmac dev`
  verb is needed. The run used scratch copies of the same code; every verb of
  the tracked script was then run once against the final build.
- ⌘, ⌘W and ⌘Q are posted to the app's pid as key events
  (`CGEvent.postToPid`; the script's `open` and `key`). `tarmac dev press`
  cannot spell `cmd+,`: its grammar takes a letter or a digit as the base.
- `scripts/qa/wheel-gesture.swift` pans the board (no verb does). A wheel
  with `--dx` over a card that is not selected pans.
- A click and a wheel at a screen point are posted at the HID tap, after
  the pointer is moved there. **A wheel posted with only its Control flag set
  leaves Control latched in the system's modifier state**: every later wheel
  then zooms, in every app, until a Control key event clears it. The helper
  must press and release Control as a key around the wheel, and the run
  checks `CGEventSource.flagsState` after it.
- Window lists come from `CGWindowListCopyWindowInfo` for the app's pid;
  captures from `screencapture -l <window id>`.

## Checks

| Scenario | Observed | Result |
| --- | --- | --- |
| **S14** Settings opens once | No font key in `.dev/app-prefs.json` (no file). *Settings…* has key equivalent `,`. A posted ⌘, gives one window titled `Settings`, 397 × 262, first in the window list and the app's main window by its `AXMain` attribute (its key state was not read apart from that). Rows in order `Terminal:`, `Interface:`, `Document:`, each selecting *System Default*, each with the sample line; `Prompt and Powerline icons need a Nerd Font.` under Terminal. No grow area (not resizable); dark. After the main window is made key (by `tarmac dev focus board`, not by a click), a second ⌘,: the window list has exactly one `Settings`, first in the list again. | pass |
| **S15** Terminal → Monaco | Before: face `.AppleSystemUIFontMonospaced-Regular`, grids 57 × 18 and 44 × 14. After, no restart: `fonts.terminal` `{"saved":"Monaco","face":"Monaco"}`, grids 57 × 15 and 44 × 12; `stty size` in the card prints `15 57`; the row's sample is in Monaco; file `{"warn_before_quit":true,"terminal_font":"Monaco"}`. | pass |
| **S16** Interface → Monaco | `fonts.interface.face` `Monaco`. Captures show Monaco in: card headers (title, owner chip, `now` recency, the header buttons), status bar, zoom control, off-screen hint pills, the ⌘K switcher (query, rows, footer and its strong text), the HTML card console, a `shell exited` toast raised after the change, and the markdown code block. No header text is clipped. Set back to *System Default* and to Monaco again: the console's text changes face and wrap point both times with no restart. | pass |
| **S17** Document → Georgia | Prose fixture `scroll.total`: 3401 on the system font, 3910 on Georgia, 3401, 3910 again, each with no restart. Capture: prose and headings in Georgia, code block in Monaco. `fonts.document.css` `"Georgia", -apple-system, "SF Pro Text", system-ui, sans-serif`. | pass |
| **S18** Relaunch | File `{"warn_before_quit":true,"terminal_font":"Monaco","interface_font":"Monaco","document_font":"Georgia"}`. After quit and `make run`: the same three `saved` values, faces `Monaco`, `Monaco` and the Georgia `css`; grids 57 × 15 and 44 × 12; the rows select Monaco, Monaco, Georgia. | pass |
| **S19** Back to System Default | Terminal → *System Default*: face `.AppleSystemUIFontMonospaced-Regular`, `saved` `null`, grids back to 57 × 18 and 44 × 14, file `{"warn_before_quit":true,"interface_font":"Monaco"}`. | pass |
| **S34** A saved family the role cannot use | File 1, `terminal_font` `No Such Family 204`, `interface_font` `Helvetica`: both `saved` as written, both faces the system monospaced face, grid 57 × 18, both rows *System Default*, the markdown code block in the system monospaced face and not Helvetica, the file's SHA-1 unchanged after launch and after the window opened. The sample lines' faces were not captured in this run. File 2, `terminal_font` `monaco`, `interface_font` `.AppleSystemUIFontMonospaced`: the same on every point. | pass |
| **S35** Events in the Settings window | Settings moved beside the main window; `drag-long.md` lies at the main-window point that equals P, a point on the `Terminal:` label. `font-settings-prose.md` selected. First click on P with the main window key, a click with Settings key, a wheel, a Control wheel: `focused_card`, `cx`, `cy` and `zoom` the same after each. | pass |
| **S36** ⌘Q and ⌘W with Settings key | ⌘W: the Settings window closes, the main window stays, 23 cards before and after. ⌘Q tap: `quit_guard.last_press.route` `guard`, the app still runs. | pass |
| **S37** A program that redraws | `top` running in the 600 × 400 card. Monaco → *System Default*: 57 × 18, `top` fills 18 rows. Back to Monaco: 57 × 15, `top` fills 15 rows. No stale cell in either capture. | pass |
| **S40** The file cannot be saved | `.dev/` made read-only, Document → Georgia: `fonts.document.saved` `Georgia` and the doc cards take it; one new stderr line `tarmac: could not save app prefs: … Code=513 …`; the file's bytes unchanged; two windows as before, no alert; the app runs on. | pass |
| **S44** The bundle | `make bundle` exits 0. `find dist/Tarmac.app -iname '*.ttf' -o -iname '*.otf' -o -iname '*.woff*'` prints nothing. `Contents/Resources` holds `DocTemplate.html`, `LICENSE`, `NOTICE`, `Tarmac.icns`, `THIRD-PARTY-LICENSES`, `Web`; no `Fonts`. Not launched. | pass |
| **S47** The two writers | Fonts Monaco, Monaco, Georgia saved. *Warn Before Quitting* chosen: `{"warn_before_quit":false,"terminal_font":"Monaco","interface_font":"Monaco","document_font":"Georgia"}`. Document → *System Default*: `{"warn_before_quit":false,"terminal_font":"Monaco","interface_font":"Monaco"}`. The item chosen again: `{"warn_before_quit":true,"terminal_font":"Monaco","interface_font":"Monaco"}`. | pass |
| **S48** Other boards, later cards | On the system font `board-0`'s terminal is 44 × 14. Back on `board-1`, Terminal → Monaco. After the switch to `board-0`, no restart: 44 × 12, and `stty size` in it prints `12 44`. ⌘T there: the new 470 × 330 terminal is 44 × 12 in the snapshot, the same grid as the 470 × 330 card beside it (`stty size` was not typed into the new card). A copy of the prose fixture opened with `tarmac open` after Document → Georgia reports `scroll.total` 3910, the Georgia figure and not the system font's 3401. | pass |

## Knockout

S35 was run again on a build with the three guards taken out (the window
number test in the press monitor, `event.window === window` in `routeScroll`
and in `routeMagnify`), then the guards were put back.

| Step | With the guards | Without them |
| --- | --- | --- |
| First click on P, main window key | selection unchanged | `focused_card` becomes `drag-long.md` |
| Click on P, Settings key | unchanged | unchanged (`handlePress` asks for the main window to be key) |
| Wheel at P | unchanged | `cy` −1563 → −1243, with no card selected |
| Control wheel at P | unchanged | `zoom` 1 → 0.1 |

The first row measures the claim the spec left open: the press monitor does
run while the main window is still key, when the first click lands on a
Settings window that is not.

On the build with the guards back, from the viewport the knockout left: a
click, a wheel and a Control wheel at P change none of `focused_card`, `cx`,
`cy` and `zoom`.

## Found during the run

- **`tarmac dev` verbs answered `not_key` while the Settings window was
  key.** `DevInput.takeKey` activated the app and waited for the main window
  to be key, which activation alone does not do when another window of the
  app holds the keys. It now also calls `makeKeyAndOrderFront`. After the
  change, `focus board` with Settings key answers `activated: true`,
  `delivery: window`.
- A terminal that is culled cannot be typed into (`not_focused`), as the
  dev-channel skill says. S48's `stty size` was read after `zoom 0.15`
  brought the card into the window.
- **`tarmac dev key <term> ctrl+c` stops interrupting once the Settings
  window has been shown.** The system's tiling items in the Window menu
  (Fill ⌃F, Center ⌃C, Return to Previous Size ⌃R) then claim the driver's
  constructed chords: with a probe on the key path, ⌃A reached
  `TerminalView.keyDown` and ⌃C, ⌃F, ⌃R did not, and ⌃F resized the window
  to 2560 × 1367. **A real keyboard is not affected:** Control with C, F and R
  posted at the HID tap, after a Settings session, ended `sleep`, reached the
  shell's history search, and left the window's frame as it was. It is not
  new with this change: on `44e0c7e`, after the menu bar is read through
  Accessibility, the same `key ctrl+c` fails. Recorded in `docs/backlog.md`
  and in the dev-channel skill; the driver is not changed here.

## Regression: `make qa`

The scenario suite of the QA driver, which covers the paths this change
touches (the press, wheel and pinch monitors, `DevInput.takeKey`, the
snapshot, the quit guard's toggle).

| Build | Board | Result |
| --- | --- | --- |
| `44e0c7e`, in a worktree of its own | fresh | 27 of 27 |
| this change, final tree | fresh | 27 of 27 |
| this change | the dev channel's long-used board | 27 of 27 once every shell was at its prompt |

Three other runs failed, none on the code: one started while the shell was
still waiting on a `pyenv rehash` lock (three shells start at once and one
waits up to 60 s); one followed a Settings session in the same process (the
⌃C limit above, D7 and D13); one had the terminal's resize handle off screen
at zoom 0.4 (D4 and D5, the suite's own stated condition).

## After the referee's first pass

Run again on the tree with its fixes, same day, same machine.

- **The font lists after the regular-face rule moved to `TarmacKit`.** The
  Terminal and Interface pop-ups list 14 entries and the Document pop-up
  255, as before the move.
- **Off-screen hint pills on screen at the change.** Two pills at the left
  edge. Interface → Monaco: both are built again, taller, with their text
  whole. Back to *System Default*: the capture of the pill region is
  byte-identical to the one taken before the change.
- **The switcher's empty list.** ⌘K, a filter that matches nothing,
  Interface → Monaco: `no boards match` is in Monaco with no restart.

## Not covered

- That the font list is read again each time the window opens. A check
  would install a font file on the tester's Mac.
- A 2× display. Monaco's cell differs from the system face's at both scales
  (spec, Context), and `TerminalViewTests` builds its views at both.
