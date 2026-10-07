# QA — a theme from a file (#218, spec 2610.0009)

The live half of
[spec 2610.0009](../.blueprint/specs/2610.0009_theme_from_file.md): its 20
`[QA]` scenarios, S44 to S63, with the values observed. Tarmac reads Ghostty
theme files from `themes/` of its config directory (`TARMAC_CONFIG_DIR`),
offers each file as a theme in Settings ▸ Theme, watches the folder, and
reports all of it in the `theme` object of `tarmac dev snapshot`.

It is also the live check for the shell of this change: `ThemeSettings`,
`ThemeFolderWatch`, `ThemeList`, `ThemePane`, `DevSnapshotReader`, and the
new verbs and lines of
[`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift).

The captures and the recordings were read during the run and are not kept
in the repository. Where a row differs from its scenario's wording, the row
says what was done. The run changed no code.

There were three runs on 2026-10-07. The first run found two things in
the app and one in the QA script (*Found on the way*). The tree was then
changed for them, and the spec too (its list *Changed after the gate*).
The second run ran S44 (its frames), S54, S62 and S63 again on that tree.
The third run ran all twenty scenarios again on the committed tree, the
commit `42d6641`: the feature (`e978a79`), a cleanup pass (`dfa3d40`) and
a fix of that pass (`42d6641`). Each row gives the values of each run that
ran it. Before the third run, a run of 15 scenarios on `dfa3d40` (all 15
passed) was stopped when the tree changed; it is not in this record.

**Result:** 20 scenarios were run. 20 pass. None fails. None was not run.
**The third run, all twenty on `42d6641`: 20 pass, none fails, none was
not run.** It found no defect. Every sampled colour, every frame and
every line of `rows` and of the snapshot that a scenario names is the
value of the first run (of the second run for the place of the list at an
open).
After the first run S54 was partial: the list was not eight rows high, as
the spec then said. The spec now says that the list is as tall as its
column of the box and not less than eight rows, and S54 compares the
`list frame=` line with that of S44. In the second run S54 passes.

Five rows pass with a limit that the row gives:

- S54: `rows` needs 34 s to 38 s for a list of 471 rows in the third run
  (99 s to 145 s in the first, 50 s to 53 s in the second). So "within
  2 s" was timed in each run with a scratch reader that asks Accessibility
  for the same values (547 ms, 518 ms and 661 ms), and one full `rows` was
  read after it (472 `theme` lines).
- S45, first run only: the main window was 1100 points wide, and the doc
  card's header was not in it. Four of the five fills were sampled, and
  the whole capture of the main window was compared (0 pixels differ). In
  the third run the window was wide and all five were sampled.
- S51: a recording does not hold sRGB values. The frames were searched for
  the Breeze Dark fills as a recording has them. These values were measured
  again in each run. In the third run the app's window came on the second
  display, so that display was recorded, with no backdrop, and the
  window's rect was searched from the window's first frame.
- S61: `17b54fe` was not built. The `make qa` result is compared with the
  27 of 27 that [`theme-choice-qa.md`](theme-choice-qa.md) has for it.
- S62: the last file theme of the list was a link to a file of Ghostty,
  which cannot be changed. It was replaced by a copy before it was applied.

The first run reported two things as defects of the app, and one as a
limit of the QA script: the height of the list, the place of the list
when the window opens with a long list, and the time `rows` needs. They
are the first, second and fourth points of *Found on the way*, each with
what the second run saw. After the second run: the height of the list is the
spec's rule; the window opens with the first row in view; `rows` is two
times as fast and is still too slow to time 2 s on a long list. One case
is a limit that the spec records (*Changed after the gate*, and *Trade-offs
and Limitations*), the third point: a list that was scrolled before the
window was closed.

**Run:** 2026-10-07, 15:02 to 15:46, macOS 26.7 (25G229), a `make run`
debug build of the branch `feat/218-ghostty-theme-file`: the commit
`17b54fe` and the working tree on it, which was not committed. One build
served the whole run; `make run` found nothing to build each time. Main
display: BenQ EW2770QZ, 2560 × 1440 at 1×. Every window of the dev app was
on this display for the whole run, so a point is a pixel. A second display
(the built-in panel, at 2×) was connected and was not used. A fresh dev
channel, `.dev/qa-218`, with its own `TARMAC_CONFIG_DIR`
(`.dev/qa-218/config`); it was removed after the run.

**The second run:** 2026-10-07, 15:53 to 16:01, the same Mac, display and
branch, the working tree after the fixes (`ThemeList.swift` and
`scripts/qa/settings-window.swift` of 15:52), still not committed. `make
run` found the build current (`Build complete! (0.37 sec)`). The script was
compiled again before the first launch. The same channel path, made fresh,
and removed after the run; its daemon was stopped before the directory was
removed.

**The third run:** 2026-10-07, 19:03 to 19:26, the same Mac, the commit
`42d6641` with a clean working tree (`git status --short` printed
nothing). `make run` found the build current (`Build complete! (0.46
sec)`). The script was compiled again before the first launch. The same
channel path, made fresh for each launch that the table calls fresh. Each
tear-down was in this order: the app by the pid of its driver socket, the
daemon with `make kill-daemon DEV_SOCKET=…`, then the channel directory.
**The displays of the third run.** In every launch the main window came
on the second display (the built-in panel, 1800 × 1169 points at 2×, at
`2910.0,139.0`), where the front app of the Mac was. Before a sample the
main window was put on the 1× display (BenQ EW2770QZ) through
Accessibility, by pid. The Settings window came on the 1× display each
time, at `847.0,250.0`; `move 847 250` was run for it after each first
`open`. So every capture by window id of the third run was of a window on
the 1× display, and a point is a pixel (each capture's size was read:
1100 × 732 or 2540 × 1150 for the main window, 873 × 530 for the Settings
window). The one read on the 2× display is the recording of S51.

**The Mac's appearance** was Light for the three runs and was not changed:
`defaults read -g AppleInterfaceStyle` answered "does not exist" at the
start and at the end of each.

**`~/.config/tarmac`** did not exist before the first run and does not
exist after the third. The runs wrote nothing there.

The first run had seven launches of the dev app, and seven more that were
stopped after their first snapshot. The second run had three. The third
run had eight, and five more that were stopped after their first snapshot:

| Launch | State at the start | Scenarios |
| --- | --- | --- |
| A | fresh channel, no config directory | the tolerance check, `make qa` (S61), S44 (with S33, S70 and the second and third parts of S53 of 2610.0008), S45, the board, then S46, S47, S48, S49, S50, S52, S53, S55 (all but its last part), S56, S58, S63, and then S35, the first part of S53, S44, S45 and S51 of 2610.0008 |
| B | the files of A, the same daemon, Dracula applied to Dark | S51, the values of a recording, the last part of S55 |
| T1 to T7 | fresh channel each time: four with no theme file, three with the 463 links | the launch times of S44 and S54. Each was stopped, with its daemon, after its first snapshot, and the channel was made empty |
| C | fresh channel with the 463 links in the folder | S54, S62 |
| D | fresh channel, no config directory | S57, first part |
| E | fresh channel, `TARMAC_CONFIG_DIR` under a regular file | S57, second part |
| F | fresh channel with a prepared `app-prefs.json` | S59 |
| G | the default channel (`make run` with no override) | S60 |
| 2A (second run) | fresh channel, no config directory | S44 (the frames), S63 |
| 2B (second run) | fresh channel with the 463 links in the folder | S54, the check of a row near the end, S62 up to a second open |
| 2C (second run) | the files of 2B, the same daemon, `Zenwritten Light` applied to Dark | S62: a first open in a launch, a second open, and the change of the file |
| 3A (third run) | fresh channel, no config directory | the tolerance check, `make qa` (S61), S44 (with S33, S70 and the second and third parts of S53 of 2610.0008), S45, the board, then S46, S47, S48, S49, S50, S52, S53, S55 (all but its last part), S56, S58, S63, and then S35, the first part of S53, S44, S45 and S51 of 2610.0008 |
| 3B (third run) | the files of 3A, the same daemon, Dracula applied to Dark. Started three times: two tries of the recording gave no file of the right display (*Found on the way*), the third is the recording of S51 | S51, the values of a recording of the second display, the last part of S55 |
| 3T1 to 3T5 (third run) | fresh channel each time: three with no theme file, two with the 463 links | the launch times of S54. Each was stopped, with its daemon, after its first snapshot, and the channel was removed |
| 3C (third run) | fresh channel with the 463 links in the folder | S54, S62 up to a second open |
| 3D (third run) | the files of 3C, the same daemon, `Zenwritten Light` applied to Dark | S62: a first open in a launch, a second open, and the change of the file |
| 3E (third run) | fresh channel, no config directory | S57, first part |
| 3F (third run) | fresh channel, `TARMAC_CONFIG_DIR` under a regular file | S57, second part |
| 3G (third run) | fresh channel with a prepared `app-prefs.json` | S59 |
| 3H (third run) | the default channel (`make run` with no override) | S60 |

After each launch the app was stopped by the pid that owned its driver
socket, and its daemon with `make kill-daemon DEV_SOCKET=<its socket>`.

## The capture tolerance

The tolerance is 1 for each channel, as in
[`theme-qa.md`](theme-qa.md). It was checked again on this tree, on the
fresh channel of launch A, with Breeze Dark. This change must not change
the values of Breeze Dark, so they are a known input.

| Fill | Value | Sampled |
| --- | --- | --- |
| board | `24282c` | `24282c` at 8 points |
| terminal body | `31363b` | `31363b` at 5 points |
| status bar | `2b3036` | `2b3036` at 5 points |
| doc card header | `353b41` | `353b41` at 2 points, after the doc card was opened |
| doc page | `2b3036` | `2b3036` at 2 points, after the doc card was opened |

**Third run**, launch 3A, the main window on the 1× display: board
`24282c` at 8 points, terminal body `31363b` at 5 points, status bar
`2b3036` at 5 points, and after the cards were opened the doc card's
header `353b41` and the doc page `2b3036` at 2 points each. (A capture
made while the window was still on the 2× display was 2200 pixels wide
and read `25282c` for the board: it was not used.)

The largest difference in a channel is 0. Each 7 × 7 square round a point
held one colour. The file that `screencapture` writes is tagged
`sRGB IEC61966-2.1`, and its bytes are read as they are. No sampled value
in this run that is held to a token is more than 0 from it.

## What it uses

- `tarmac dev snapshot`, and a capture by `screencapture -o -l <window id>`
  of a window of the app's pid. A sample point is computed from the
  snapshot's `content_origin` and a card's `screen_rect`, never typed by
  hand.
- **The five fills** are the board, the doc card's header, the terminal
  body, the status bar and the doc page, in this order. The points: four
  board points that are 100 points or more from every card; the header 140
  and 165 points from the card's left edge, 14 points down; the terminal
  body 40 and 120 points from the card's right edge, near its bottom; the
  status bar 13 points under the view, at two places; the doc page 6 points
  from the card's left edge, at two heights. Each is the middle of a 7 × 7
  square of one colour.
- The main window comes at 1100 × 732. It was made 2540 × 1150 through
  Accessibility, and the board was moved with a real wheel
  ([`scripts/qa/wheel-gesture.swift`](../scripts/qa/wheel-gesture.swift)),
  so that the terminal card, [`theme-doc.md`](theme-doc.md) and
  [`theme-console.html`](theme-console.html) show whole at zoom 1. The two
  cards of `make qa` (`d17.md`, `d18.html`) were on the board too.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift),
  compiled once: `open`, `rows`, `pane`, `theme`, `show`, `apply`,
  `open-themes`, `menu`, `key`, `wheel`.
- **A time** is counted from the return of the command that changed the
  folder to the return of the first read that shows the result. Three
  kinds of read: a snapshot (about 10 ms each); a capture of the window and
  one pixel of it (about 130 ms each); a `rows` read (0.1 s to 0.3 s with
  nine rows). The row says which.
- **A change in place** keeps the file's inode: the file is opened for
  update, written and cut to its new length. **A change by rename** writes
  a second file in the folder and runs `mv` over the first: the inode
  changes.
- *The Settings window is dark* or *light*: the pane's fill 40 points right
  of the label *Appearance*, and the fullest pixel of that label, compared
  by luminance.
- **A tile's picture** is 66 × 44 points, 5 points in from the left edge
  and from the top edge of the tile's frame. Its sample point is 4 points
  in from the middle of its left edge. **The showcase's picture:** the
  board at (6, 113) from the origin of the `picture frame=` line, the
  terminal body at (150, 150), the doc page at (280, 150).
- A scratch script in the terminal card prints four lines with ANSI 2 as
  the background, sends `OSC 11 ; ?` and logs the answer.
- A recording is 60 fps `ffmpeg` of the screen device `Capture screen 0`,
  kept without loss (`libx264rgb`, `-crf 0`). Its colours are not sRGB
  values. Measured in this run on the dev window: the Breeze Dark board
  `24282c` is `202327` in a recording, the header `353b41` is `2e3339`, the
  terminal body `31363b` is `2b2f33`, the status bar `2b3036` is `262a2f`.
  The Dracula board `171a27` is `161822` and its terminal body `282a36` is
  `23252f`.
- Scratch tools, not kept: one lists the windows of a pid and the window at
  a point, reads the lock state and the front app, and raises a window
  through Accessibility; one reads the list of themes through Accessibility
  (the count of rows, the first row, the selected row, the rows in view)
  in less than 1 s for 472 rows; one puts an opaque window over the main
  display for the recording of S51.
- Before each `wheel` the window at the point was read: it was the Settings
  window of the dev pid each time. The screen was not locked at any
  press-based step.

*Dracula* is the text of the spec, which is the file of Ghostty 1.3.1
(`diff` finds no difference). *Dracula five* is `171a27`, `373843`,
`282a36`, `20222e`, `20222e`. *Breeze Dark five* is `24282c`, `353b41`,
`31363b`, `2b3036`, `2b3036`. *The folder* is
`.dev/qa-218/config/themes`.

## Checks

### The folder, live

| Scenario | Observed | Result |
| --- | --- | --- |
| **S44** A fresh channel with no config directory | Launch A. First snapshot, 4159 ms after `make run` was called: `"name":"breeze-dark"`, `"folder":"/Users/eplin/workspace/tarmac/.dev/qa-218/config/themes"`, `available` `["breeze-light","breeze-dark","catppuccin-latte","catppuccin-mocha","github-light","github-dark","solarized-light","solarized-dark"]`, `"refused":[]`, `"choice":"dark"`, `"in_effect":"dark"`, and five `findings` lines for Breeze Dark. Settings on *Theme*: `rows` prints eight `theme` lines, each with its id (`theme Breeze Light marks=Light selected=0 frame=1055.0,413.0 260.0x24.0 id=breeze-light` to `theme Solarized Dark … id=solarized-dark`), `list frame=1055.0,403.0 260.0x327.0`, `files No theme files.`, `files-help ` with no value, `button Open Themes Folder frame=1569.0,739.0 132.0x22.0`. After `make qa`, both panes, eight `show` calls and four refused `apply` calls, the config directory still does not exist, and the channel holds no `app-prefs.json`. **The frame:** `window frame=847.0,250.0 873.0x530.0` on *Fonts*, on *Theme*, and after two more changes of pane each way. On `17b54fe` it was 873 × 488: the width is the same and the height is 42 points more. `resizable=false`. Every frame that `rows` prints lies inside the window's frame: 17 frames on *Fonts*, 34 on *Theme*. `show "GitHub Light"`: `note Every terminal colour passes the contrast floors.` and `note-help ` with no value. **Second run** (launch 2A, the frames): first snapshot 3062 ms after the call, the eight ids, the same `folder`. `window frame=847.0,250.0 873.0x530.0` on *Fonts*, on *Theme*, and after one more change each way; `resizable=false`; `list frame=1055.0,403.0 260.0x327.0`; `button Open Themes Folder frame=1569.0,739.0 132.0x22.0`; the eight `theme` lines from `frame=1055.0,413.0 260.0x24.0` to `1055.0,581.0`; 17 frames on *Fonts* and 34 on *Theme*, all inside the window. Every frame is the frame of the first run. The config directory did not exist after it. **Third run** (`42d6641`): launch 3A. First snapshot, 3178 ms after the call: `"name":"breeze-dark"`, the same `folder`, the eight ids in the same order, `"refused":[]`. `rows` on *Theme*: the eight `theme` lines from `frame=1055.0,413.0 260.0x24.0 id=breeze-light` to `1055.0,581.0 … id=solarized-dark`, `list frame=1055.0,403.0 260.0x327.0`, `files No theme files.`, `files-help ` empty, `button Open Themes Folder frame=1569.0,739.0 132.0x22.0`. `window frame=847.0,250.0 873.0x530.0` on *Fonts*, on *Theme* and after two more changes each way; `resizable=false`; 17 frames on *Fonts* and 34 on *Theme*, all inside. `show "GitHub Light"`: the same `note` and an empty `note-help`. After `make qa`, both panes, eight `show` calls and four refused `apply` calls: no config directory and no `app-prefs.json`. Every frame and line is that of the first run. | pass, in the three runs |
| **S45** The folder made after the launch | The state of S44, the Settings window open, Breeze Dark selected. `mkdir -p` of the folder and a copy of Dracula into it. A snapshot shows `file:Dracula` as the ninth and last id of `available` 420 ms after the command. No restart (the same pid). `rows`, read in the 334 ms after that: the eight lines as before and then `theme Dracula marks= selected=0 frame=1055.0,605.0 260.0x24.0 id=file:Dracula`; `files 1 theme from a file.`; the selected row is still Breeze Dark; `showcase title=Breeze Dark caption=dark theme`. The showcase's picture: 0 of its 81 812 pixels differ from the capture before. The snapshot's `name` is `breeze-dark`. Board `24282c`, terminal body `31363b`, status bar `2b3036`, doc page `2b3036`, before and after; the header of the doc card was outside the window. 0 of the 805 200 pixels of the main window differ between the capture before and the one after. The channel holds no `app-prefs.json`. **Third run** (`42d6641`): the main window was 2540 points wide, so all five fills were sampled. `file:Dracula` is the ninth and last id 217 ms after the command; the same pid. `rows`, read in the 303 ms after that: nine lines, the last `theme Dracula marks= selected=0 frame=1055.0,605.0 260.0x24.0 id=file:Dracula`; `files 1 theme from a file.`; the selected row is Breeze Dark; `showcase title=Breeze Dark caption=dark theme`; 0 of the 81 812 pixels of the showcase's picture differ. `name` is `breeze-dark`. Five, before and after: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. 0 of the 2 921 000 pixels of the main window differ. No `app-prefs.json`. | pass. First run: four of the five fills. Third run: all five |
| **S46** A file theme applied | The board as *What it uses* says, `theme-doc.md` scrolled to `scroll.offset` 400. `show Dracula` prints `shown Dracula`; `apply Dark on` prints `box Apply to Dark value=1 enabled=1`, status 0. `rows`: `theme Dracula marks=Dark selected=1 … id=file:Dracula`, `marks=` empty on Breeze Dark, `showcase title=Dracula caption=dark theme, from a file`, `note 1 terminal colour has low contrast on the background.`, `note-help ansi 0 on background: 1.11 (floor 3)`. Snapshot: `"choice":"dark"`, `"in_effect":"dark"`, `"name":"file:Dracula"`, `"findings":["ansi 0 on background: 1.11 (floor 3)"]`. File: `{"warn_before_quit":true,"theme_dark":"file:Dracula"}`. Five: `171a27`, `373843`, `282a36`, `20222e`, `20222e`. The four lines with ANSI 2 as the background are `50fa7b`: 37 712 pixels of the card, and three points in them. The answer to `OSC 11 ; ?` is `ESC ] 11 ; rgb:2828/2a2a/3636 ESC \`. **Third run** (`42d6641`): the same `shown`, `box`, `theme`, `showcase`, `note` and `note-help` lines, the same snapshot (`"name":"file:Dracula"`, the one `findings` line) and the same file. Five: `171a27`, `373843`, `282a36`, `20222e`, `20222e`. ANSI 2 as a background: `50fa7b`, 38 021 pixels of the card. `OSC 11 ; ?`: `ESC ] 11 ; rgb:2828/2a2a/3636 ESC \`. **The scroll thumb** of `theme-doc.md` under Dracula, in a capture while it showed (`scroll.thumb` `2056,478 10x45`): fill `181b1d` (312 of the 450 pixels of its rect), line `696b6c` (70 pixels). | pass, in the first and the third run |
| **S47** The file changes under the theme in effect | **In place**, `background = #1e1f29` (the inode is the same, `318277016`): the snapshot's `findings` changed 404 ms after the command (to `ansi 0 on background: 1.04 (floor 3)`), and a capture shows the terminal body `1e1f29` at 518 ms. Five: `0d0e19`, `2d2e37`, `1e1f29`, `151621`, `151621`: the board, the header and the page are the derived `bg0`, `bg2` and `bg1`. The *Dark* tile's picture `0d0e19` (it was `171a27`); 2740 of the 5320 pixels of the tile differ. The showcase's picture `0d0e19`, `1e1f29`, `151621` at its three points (it was `171a27`, `282a36`, `20222e`); 79 847 of its 81 812 pixels differ. **By rename**, back to `#282a36` (the inode changed to `318277714`): a capture shows the terminal body `282a36` at 312 ms, the snapshot at 326 ms. Five: `171a27`, `373843`, `282a36`, `20222e`, `20222e`. The tile and the showcase: 0 pixels differ from the capture before the first change. Each time: the snapshot's `name` is `file:Dracula`; the selected row is Dracula; `scroll.offset` 400 and `scroll.total` 1654 of the doc card, before and after; the SHA-1 and the modification time of `app-prefs.json` are the same; the same pid. **Third run** (`42d6641`): **in place** (inode `318352478` before and after): the snapshot at 267 ms, the capture at 384 ms. Five: `0d0e19`, `2d2e37`, `1e1f29`, `151621`, `151621`. The *Dark* tile `0d0e19`, 2740 of its 5320 pixels differ; the showcase `0d0e19`, `1e1f29`, `151621`, 79 847 of its 81 812 pixels differ. **By rename** (the inode changed to `318352677`): the capture at 247 ms, the snapshot at 259 ms. Five: `171a27`, `373843`, `282a36`, `20222e`, `20222e`; the tile and the showcase: 0 pixels differ from the capture before the first change. Each time: `name` `file:Dracula`, the selected row Dracula, `scroll.offset` 406 and `scroll.total` 1654 before and after, the SHA-1 and the modification time of `app-prefs.json` the same, the same pid. | pass, in the first and the third run |
| **S48** Tarmac's keys in the file | The line `tarmac-bg0 = #101010` added in place: the first capture, 136 ms after the command, shows the board `101010`. Five: `101010`, `373843`, `282a36`, `20222e`, `20222e`. The line `tarmac-muted = #6272a4` added: the snapshot has four `findings` 26 ms after the command. `rows`: `note 1 terminal colour has low contrast on the background. 1 chrome colour has low contrast.` and `note-help ansi 0 on background: 1.11 (floor 3) \| muted on bg0: 4.04 (floor 4.5) \| muted on bg1: 3.36 (floor 4.5) \| muted on bg2: 2.47 (floor 4.5)`: four parts. The snapshot's `findings` holds the same four lines. **Third run** (`42d6641`): the board is `101010` in the first capture, 120 ms after the command. Five: `101010`, `373843`, `282a36`, `20222e`, `20222e`. After the second line the snapshot has four `findings` at 26 ms. `rows`: the same `note` line, and the same `note-help` of four parts with the same four ratios (1.11, 4.04, 3.36, 2.47). | pass, in the first and the third run |
| **S49** The file is no theme | Dracula written whole again first (five: Dracula five). The `foreground` line removed in place: the snapshot's `name` is `breeze-dark` 153 ms after the command, and a capture shows the terminal body `31363b` at 277 ms. Five: Breeze Dark five. Snapshot: `"name":"breeze-dark"`, `available` the eight built-in ids, `"refused":["Dracula: has no foreground"]`. `rows`: eight `theme` lines, `theme Breeze Dark marks=Dark selected=1`, `showcase title=Breeze Dark caption=dark theme`, `files 1 file was not read.`, `files-help Dracula: has no foreground`. `app-prefs.json` is `{"warn_before_quit":true,"theme_dark":"file:Dracula"}`, the same SHA-1. The app has its two windows and no other (read through Accessibility), and no new line on stderr. **The line put back:** the snapshot's `name` is `file:Dracula` at 165 ms, the capture shows `282a36` at 288 ms. Five: Dracula five. `rows`: nine lines, `marks=Dark` on Dracula. **Third run** (`42d6641`): the line removed: `name` `breeze-dark` at 153 ms, the capture `31363b` at 288 ms. Five: `24282c`, `353b41`, `31363b`, `2b3036`, `2b3036`. Snapshot: the eight ids, `"refused":["Dracula: has no foreground"]`. `rows`: 8 `theme` lines, `theme Breeze Dark marks=Dark selected=1`, `files 1 file was not read.`, `files-help Dracula: has no foreground`. `app-prefs.json` the same bytes, with `"theme_dark":"file:Dracula"`. The app's two windows and no other; stderr has 149 lines before and after. **The line put back:** the capture `282a36` at 148 ms, `name` `file:Dracula` at 160 ms. Five: Dracula five. Nine lines, `marks=Dark` on Dracula. | pass, in the first and the third run |
| **S50** The file is removed | `rm` of the file: `name` `breeze-dark` at 147 ms, the capture `31363b` at 264 ms. Five: Breeze Dark five. Snapshot: `available` the eight ids, `"refused":[]`. `rows`: eight `theme` lines, `marks=Dark` on Breeze Dark, `files No theme files.`, `files-help ` empty. File: `{"warn_before_quit":true,"theme_dark":"file:Dracula"}`. *Warn Before Quitting (⌘Q)* chosen in the app menu: file `{"warn_before_quit":false,"theme_dark":"file:Dracula"}`. **The file written again:** `name` `file:Dracula` at 193 ms, the capture `282a36` at 325 ms. Five: Dracula five. (The menu item was then chosen again: `"warn_before_quit":true`.) **Third run** (`42d6641`): `rm`: the capture `31363b` at 311 ms, `name` `breeze-dark` at 322 ms. Five: Breeze Dark five. `"refused":[]`, 8 `theme` lines, `marks=Dark` on Breeze Dark, `files No theme files.`, `files-help ` empty. After *Warn Before Quitting (⌘Q)*: `{"warn_before_quit":false,"theme_dark":"file:Dracula"}`. **The file written again:** `name` `file:Dracula` at 159 ms, the capture `282a36` at 273 ms. Five: Dracula five. | pass, in the first and the third run |
| **S51** A relaunch | The state of S46: file `{"warn_before_quit":true,"theme_dark":"file:Dracula"}`, five Dracula five. The app was stopped by its pid. An opaque magenta window was put over the main display under the menu bar, a recording of 13 s was started, and `make run` was called. First snapshot, 3750 ms after the call: `"choice":"dark","in_effect":"dark","name":"file:Dracula"`, nine ids in `available`. **The recording:** 780 frames, 2560 × 1440. The dev window is in it from frame 294, with no frame between the backdrop and the window. No frame holds a flat area of 4 × 4 pixels, with a tolerance of 1, of `202327`, `2e3339`, `2b2f33` or `262a2f` (the Breeze Dark board, header, terminal body and `bg1` as a recording has them) in the area under the menu bar. A board point of the window is `161822` (the Dracula board in a recording) from frame 294 to the last frame, and 486 frames hold flat areas of it. Five, with the window at its size again: `171a27`, `373843`, `282a36`, `20222e`, `20222e`. The SHA-1 of `app-prefs.json` is the same after the launch. **Third run** (`42d6641`): the state of S46 (the same file, Dracula five). The app was stopped by its pid and `make run` was called. The main window came on the second display (the built-in panel at 2×, frame `2910.0,139.0 1100.0x732.0`), so the recording is of that display (`Capture screen 1`, 3600 × 2338, 12 s, 720 frames), with no backdrop. First snapshot, 3995 ms after the call: `"choice":"dark","in_effect":"dark","name":"file:Dracula"`, nine ids. The values of a recording of that display, measured on the dev window in this launch: the Breeze Dark board `202326`, header `2e3439`, terminal body `2b2f33`, `bg1` `262a2f`; the Dracula board `161822`. **The window is in the recording from frame 284:** a board point, a point of the title bar and a point of the status bar change in that one frame, and the board point is `161822` from there to the last frame. In the window's rect, in the 436 frames from 284 to 719: no flat area of 4 × 4 pixels, with a tolerance of 1, of the four Breeze Dark values; each of the 436 frames holds flat areas of `161822`. A control: the same search of a recording of 1 s of the window under Breeze Dark finds each of the four values in all 60 frames. Five, with the window on the 1× display again: `171a27`, `373843`, `282a36`, `20222e`, `20222e`. The SHA-1 of `app-prefs.json` is the same. | pass, in the first and the third run (the third on the second display, with the window's rect searched from its first frame) |
| **S52** The folder itself is removed | `rm -r` of the folder: the capture shows `31363b` at 170 ms, the snapshot's `name` is `breeze-dark` at 182 ms. Five: Breeze Dark five. `rows`: 8 `theme` lines, `files No theme files.`; snapshot `"refused":[]` and the same `folder`. **`mkdir` of the folder and a copy of Dracula:** the capture shows `282a36` at 262 ms, `name` `file:Dracula` at 273 ms. Five: Dracula five. `rows`: 9 lines, `marks=Dark` on Dracula. The same pid as at the launch: no restart. **Third run** (`42d6641`): `rm -r`: `name` `breeze-dark` at 29 ms, the capture `31363b` at 154 ms. Five: Breeze Dark five. 8 `theme` lines, `files No theme files.`, `"refused":[]`, the same `folder`. **`mkdir` and a copy of Dracula:** the capture `282a36` at 254 ms, `name` `file:Dracula` at 266 ms. Five: Dracula five. 9 lines, `marks=Dark` on Dracula. The same pid. | pass, in the first and the third run |
| **S53** A file with the title of a built-in theme | The file `Catppuccin Mocha` of Ghostty copied into the folder (in `available` 43 ms after the command). `rows`: `theme Catppuccin Mocha marks= selected=0 … id=catppuccin-mocha` as the fourth line and `theme Catppuccin Mocha marks= selected=0 … id=file:Catppuccin Mocha` as the ninth, before Dracula. `show "file:Catppuccin Mocha"`: the selected row is the ninth, `showcase title=Catppuccin Mocha caption=dark theme, from a file`. `apply Dark on`: snapshot `"name":"file:Catppuccin Mocha"`; five `100f1e`, `2a2b3c`, `1e1e2e`, `171726`, `171726` (the board of the built-in theme is `11111b`); `marks=Dark` on the row with `id=file:Catppuccin Mocha` and `marks=` empty on the row with `id=catppuccin-mocha`. `show "Catppuccin Mocha"`: the selected row is the one with `id=catppuccin-mocha`, `showcase title=Catppuccin Mocha caption=dark theme`, `box Apply to Light value=0 enabled=1`, `box Apply to Dark value=0 enabled=1`. **Third run** (`42d6641`): the file is in `available` 228 ms after the copy. `rows`: `theme Catppuccin Mocha … id=catppuccin-mocha` as the fourth line and `theme Catppuccin Mocha … id=file:Catppuccin Mocha` as the ninth, before Dracula. `show "file:Catppuccin Mocha"`: the ninth is selected, `caption=dark theme, from a file`. `apply Dark on`: `"name":"file:Catppuccin Mocha"`; five `100f1e`, `2a2b3c`, `1e1e2e`, `171726`, `171726`; `marks=Dark` on the row with `id=file:Catppuccin Mocha`, none on the row with `id=catppuccin-mocha` and none on Dracula. `show "Catppuccin Mocha"`: the row with `id=catppuccin-mocha` is selected, `caption=dark theme`, both boxes `value=0 enabled=1`. | pass, in the first and the third run |
| **S54** 463 files | See *S54, part by part* below. **Third run** (`42d6641`): the third column of *S54, part by part*. | pass in the second and in the third run (the "2 s" clause timed with the scratch reader, and one full `rows` after it). Partial in the first run, by the text the spec then had for the height of the list |
| **S55** The shown theme, and a window that is not open | **The shown file is removed.** `file:Catppuccin Mocha` in effect, Dracula in the folder and not applied, `show Dracula` (`showcase title=Dracula caption=dark theme, from a file`). `rm` of Dracula: the `rows` read that started 282 ms after the command and ended at 392 ms prints `showcase title=Catppuccin Mocha caption=dark theme, from a file` and `theme Catppuccin Mocha marks=Dark selected=1 … id=file:Catppuccin Mocha`. **The shown file changes.** Dracula written again, `show Dracula`, then `background = #1e1f29` in place: a capture shows the showcase's terminal body `1e1f29` at 171 ms; its three points are `0d0e19`, `1e1f29`, `151621` (they were `171a27`, `282a36`, `20222e`); the selected row is Dracula; the snapshot's `name` and the five of the main window are still those of `file:Catppuccin Mocha`. **A window that is not open.** With Dracula as the one file and nothing applied, the Settings window was closed (`key 13`, after it was made the app's main window; the app then has one window). `rm` of Dracula, `open`: `pane=Theme`, 8 `theme` lines, `files No theme files.` Closed again, Dracula written, `open`: 9 `theme` lines, `theme Dracula … id=file:Dracula`, `files 1 theme from a file.` **A window that was never opened.** Launch B, where the Settings window was not opened: the file `Later` written into the folder (the snapshot then has `file:Later`), then the first `open` and `pane Theme`: 10 `theme` lines, the last `theme Later marks= selected=0 id=file:Later`, `files 2 themes from files.` **Third run** (`42d6641`): **The shown file is removed:** the `rows` read that started 188 ms after the `rm` and ended at 260 ms prints `showcase title=Catppuccin Mocha caption=dark theme, from a file` and that row selected with `marks=Dark`. **The shown file changes:** a capture shows the showcase's terminal body `1e1f29` at 184 ms; its three points are `0d0e19`, `1e1f29`, `151621`; the selected row is Dracula; `name` and the five are still those of `file:Catppuccin Mocha` (`100f1e`, `2a2b3c`, `1e1e2e`, `171726`, `171726`). **A window that is not open:** closed, `rm`, `open`: `pane=Theme`, 8 `theme` lines, `files No theme files.`, Breeze Dark selected with `marks=Dark`; closed, the file written, `open`: 9 lines, `theme Dracula marks= selected=0 id=file:Dracula`, `files 1 theme from a file.` **A window that was never opened** (launch 3B, Dracula applied to Dark): `Later` written, then the first `open` and `pane Theme`: 10 `theme` lines, the last `theme Later marks= selected=0 id=file:Later`; `theme Dracula marks=Dark selected=1`; `showcase title=Dracula caption=dark theme, from a file`; `files 2 themes from files.` | pass, in the first and the third run |
| **S56** A file that changes its variant | The Mac Light. `theme Light`: `{"choice":"light","in_effect":"light","name":"breeze-light"}`, the Settings window light (fill `f7f7f7`, luminance 0.930; label `262626`, 0.019). `show Dracula`, `apply Light on`: `{"choice":"light","in_effect":"dark","name":"file:Dracula"}`; the window dark (fill `343637`, 0.036; label `e0e0e0`, 0.745); five Dracula five; file `{"warn_before_quit":true,"theme":"light","theme_light":"file:Dracula"}`. **The file `Latte`** (the Catppuccin Latte file of Ghostty) copied into the folder, `show Latte`, `apply Light on`: `{"choice":"light","in_effect":"light","name":"file:Latte"}`; the window light (`f7f7f7`, `262626`); five `dfe1e7`, `d7d9e0`, `eff1f5`, `e7e9ee`, `e7e9ee`, the Latte column of the spec; `showcase title=Latte caption=light theme, from a file`. **The two values exchanged** (`background = #4c4f69`, `foreground = #eff1f5`, written in place): `in_effect` is `dark` 272 ms after the command; `{"choice":"light","in_effect":"dark","name":"file:Latte"}`; the window dark (`343637`, `e0e0e0`); five `3f425e`, `575a73`, `4c4f69`, `454963`, `454963`; `showcase title=Latte caption=dark theme, from a file`; `marks=Light` on Latte; the file `app-prefs.json` did not change. **Third run** (`42d6641`): `theme Light`: `breeze-light`, the window light (fill `f7f7f7`, 0.930; label `262626`, 0.019). Dracula applied to Light: `{"choice":"light","in_effect":"dark","name":"file:Dracula"}`, the window dark (`343637`, 0.036; `e0e0e0`, 0.745), Dracula five. `Latte` applied to Light: `{"choice":"light","in_effect":"light","name":"file:Latte"}`, the window light, five `dfe1e7`, `d7d9e0`, `eff1f5`, `e7e9ee`, `e7e9ee`, `caption=light theme, from a file`. The two values exchanged in place: `in_effect` `dark` at 71 ms, `name` `file:Latte`, the window dark (`343637`, `e0e0e0`), five `3f425e`, `575a73`, `4c4f69`, `454963`, `454963`, `caption=dark theme, from a file`, `marks=Light` on Latte, `app-prefs.json` the same bytes. | pass, in the first and the third run |
| **S57** *Open Themes Folder* | **Launch D**, a fresh channel, no config directory. `open-themes`, status 0: `config` and `config/themes` exist. The Finder: `name of every Finder window` was `video` before and is `themes, video` after; `POSIX path of (target of front window as alias)` is `/Users/eplin/workspace/tarmac/.dev/qa-218/config/themes/`; the front app is the Finder. No new line on stderr. That one Finder window was then closed. **Launch E**, `TARMAC_CONFIG_DIR=.dev/qa-218/notadir/config`, where `notadir` is a regular file. The snapshot's `folder` is `…/qa-218/notadir/config/themes`, with the eight ids. `open-themes`, status 0: stderr has 33 lines where it had 32; the new line is `tarmac: could not make the themes folder: Error Domain=NSCocoaErrorDomain Code=512 "The file “notadir” couldn’t be saved in the folder “qa-218”." … "Not a directory"`. `notadir` is still a regular file of 15 bytes, and no folder was made. The Finder's windows are the same (`video`). The app has its two windows and no other, the same pid, and a snapshot is answered. **Third run** (`42d6641`): **launch 3E**, no config directory: `open-themes`, status 0; `config` and `config/themes` exist; the Finder's windows were `video` and are `themes, video`; the front window's path is `/Users/eplin/workspace/tarmac/.dev/qa-218/config/themes/`; stderr has 32 lines before and after. That Finder window was closed (`video` is left). **Launch 3F**, the config directory under the regular file `notadir`: the snapshot's `folder` is `…/qa-218/notadir/config/themes`; `open-themes`, status 0: 33 lines where there were 32, the new one `tarmac: could not make the themes folder: … Code=512 …`; `notadir` is a regular file of 15 bytes still; the Finder's windows are the same; two windows of the app, the same pid, a snapshot answered. | pass, in the first and the third run |
| **S58** Files that are refused | No theme file in the folder. One file at a time, then `files-help` and the snapshot's `refused`: the bytes `ff fe 00`: `notutf8: is not UTF-8 text`. A file of 65 537 bytes: `big: is larger than 64 KiB`. `background = red` on line 3: `line3: line 3: the value of background cannot be read`. A `foreground` line only: `nobg: has no background`. Each time `files 1 file was not read.` and 8 `theme` lines. **Two at one time**, `a` (not UTF-8) and `b` (no background): `files 2 files were not read.`, `files-help a: is not UTF-8 text \| b: has no background`, snapshot `"refused":["a: is not UTF-8 text","b: has no background"]`. **Names that are not read:** a folder `sub` with a Dracula file in it, a file `.hidden` and a file `Old~`, each with the Dracula text, added beside `a` and `b`: the same two lines and 8 `theme` lines. With `a` and `b` removed and the three still there: `files No theme files.`, `files-help ` empty, `"refused":[]`, 8 `theme` lines. **Third run** (`42d6641`): the four reasons, each file in the snapshot's `refused` 65 ms to 76 ms after its copy: `notutf8: is not UTF-8 text`; `big: is larger than 64 KiB` (65 537 bytes); `line3: line 3: the value of background cannot be read`; `nobg: has no background`; each time `files 1 file was not read.` and 8 `theme` lines. `a` and `b`: `files 2 files were not read.`, `files-help a: is not UTF-8 text \| b: has no background`. `sub`, `.hidden`, `Old~` added: the same two lines and 8 lines; with `a` and `b` removed: `files No theme files.`, `"refused":[]`. **What is no file**, added one at a time beside those three, each read 1.2 s after it was made: a named pipe with mode 644 (`Pipe`), a named pipe with mode 000 (`PipeNo`), a folder with mode 000 (`DirNo`), and a Unix socket (`Sock`, bound by a process that stayed alive). After each one: 8 `theme` lines, `files No theme files.`, `files-help ` empty, `"refused":[]`, no line of `rows` holds its name, and a snapshot was answered (113, 104, 104 and 101 ms). **With the four there**, Dracula copied in: in `available` after 225 ms, a ninth row `theme Dracula marks= selected=0 id=file:Dracula`, `files 1 theme from a file.`, `files-help ` empty. **What cannot be read:** a link to nothing (`Dangling`): `"refused":["Dangling: cannot be read"]`, `files 1 theme from a file. 1 file was not read.`, `files-help Dangling: cannot be read`. A file with mode 000 and the Dracula text (`Locked`): `"refused":["Dangling: cannot be read","Locked: cannot be read"]`, `files 1 theme from a file. 2 files were not read.`, `files-help Dangling: cannot be read \| Locked: cannot be read`; 9 `theme` lines, no row for either. The same pid and the app's two windows. Then the permissions were put back, the socket's process was stopped by its pid, and all was removed: `files No theme files.`, `"refused":[]`. | pass, in the first and the third run |
| **S59** Ids that no theme has | Launch F. File written before the launch: `{"warn_before_quit":true,"terminal_font":"Menlo","theme_light":"file:Gone","theme_dark":"sepia"}`. First snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, `fonts.terminal` `{"face":"Menlo-Regular","saved":"Menlo","size":16}`. `rows`: `marks=Light` on Breeze Light, `marks=Dark` on Breeze Dark and selected, `marks=` empty on the other six, `tile Dark value=1`; on *Fonts* `0 selected=Menlo`. After the launch and both panes, the file's SHA-1 and modification time are the same. *Warn Before Quitting (⌘Q)* chosen in the app menu: file `{"warn_before_quit":false,"terminal_font":"Menlo","theme_light":"file:Gone","theme_dark":"sepia"}`. The config directory was not made. **Third run** (`42d6641`): launch 3G, the same bytes written before the launch. First snapshot: `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, the eight ids, `fonts.terminal` `{"face":"Menlo-Regular","saved":"Menlo","size":16}`. `rows`: `marks=Light` on Breeze Light, `marks=Dark` on Breeze Dark and selected, none on the other six, `tile Dark value=1`; on *Fonts* `0 selected=Menlo`. The file's SHA-1 and modification time are the same after the launch and both panes. After *Warn Before Quitting (⌘Q)*: `{"warn_before_quit":false,"terminal_font":"Menlo","theme_light":"file:Gone","theme_dark":"sepia"}`. No config directory. | pass, in the first and the third run |
| **S60** The default channel | Launch G, `make run` with no override. Its command line has `TARMAC_CONFIG_DIR="/Users/eplin/workspace/tarmac/.dev/config"`. First snapshot: `"folder":"/Users/eplin/workspace/tarmac/.dev/config/themes"`, eight ids; `.dev/config` did not exist. Settings on *Theme*: 8 `theme` lines, `files No theme files.` `mkdir -p` of that folder and a copy of Dracula as `QA218-Test`: the `rows` read that started 175 ms after the command and ended at 283 ms prints `theme QA218-Test marks= selected=0 frame=1055.0,605.0 260.0x24.0 id=file:QA218-Test` and `files 1 theme from a file.`; the snapshot's `available` ends with `file:QA218-Test`. The file was then removed (8 lines again), and the two folders that the run had made were removed. **Third run** (`42d6641`): launch 3H. The command line has `TARMAC_CONFIG_DIR="/Users/eplin/workspace/tarmac/.dev/config"`; the first snapshot has `"folder":"/Users/eplin/workspace/tarmac/.dev/config/themes"` and eight ids; `.dev/config` did not exist. 8 `theme` lines, `files No theme files.` `QA218-Test` written: the `rows` read that started 76 ms after the command and ended at 195 ms prints `theme QA218-Test marks= selected=0 frame=1055.0,605.0 260.0x24.0 id=file:QA218-Test` and `files 1 theme from a file.`; `available` ends with `file:QA218-Test`. The file and the two folders were removed. | pass, in the first and the third run |
| **S61** `make qa`, and seven scenarios of 2610.0008 | **`make qa`** with the two overrides of the launch, in launch A before the Settings window was shown, with the terminal's `proc` at `zsh`: `27/27 checks passed`, S21 skipped (the dev app was in front). `theme-choice-qa.md` has 27 of 27 with S21 skipped for the tree that became `17b54fe`; that commit was not built here. No config directory and no `app-prefs.json` after it. **The seven scenarios:** the table *The scenarios of 2610.0008* below. All seven pass. **Third run** (`42d6641`): `make qa` in launch 3A, before the Settings window was shown, `proc` at `zsh`: `27/27 checks passed`, S21 skipped. No config directory and no `app-prefs.json` after it. The seven scenarios were run again and pass: the table below has their values. | pass, in the first and the third run (`17b54fe` from the earlier record) |
| **S62** The selected row is in view | Launch C, 464 file themes (the 463 links and `Aaa`). The last by the order of the list is `Zenwritten Light`. Its link was replaced by a copy of the file, so that it can be changed. `show "file:Zenwritten Light"`, `apply Dark on`: snapshot `"name":"file:Zenwritten Light"`, file `{"warn_before_quit":true,"theme_dark":"file:Zenwritten Light"}`. The window closed (`key 13`) and opened (`open`), on *Theme*: the selected row is `Zenwritten Light marks=Dark selected=1 frame=1055.0,706.0 260.0x24.0 id=file:Zenwritten Light`, and `list frame=1055.0,403.0 260.0x327.0`: the row is from y 706 to y 730, and the list from y 403 to y 730. The run did not scroll. **Then** two `wheel` calls over the list: the first row is at `1055.0,413.0`, the selected row at y 11717, out of view. `background = #e0e0e0` written in place: the read that started 123 ms after the command and ended at 510 ms has the selected row as the last row in view, at `1055.0,706.0 260.0x24.0`. The snapshot's `name` is `file:Zenwritten Light`. These reads are of the scratch reader (the selected row and the rows in view, as Accessibility gives them). **Second run**, 464 file themes again, `Zenwritten Light` a copy and applied to Dark (`"name":"file:Zenwritten Light"`). **A second open** in launch 2B (`key 13`, `open`): the selected row is `Zenwritten Light marks=Dark selected=1 frame=1055.0,706.0 260.0x24.0 id=file:Zenwritten Light`, the last of the 14 rows in view; `list frame=1055.0,403.0 260.0x327.0`. **A first open in a launch** (launch 2C, the first snapshot has `file:Zenwritten Light`; `open`, `pane Theme`): the same line, y 706 to y 730 in a list from y 403 to y 730. **A second open** in launch 2C: the same line. The run did not scroll before any of the three. **Then** two `wheel` calls: the first row at `1055.0,413.0`, the selected row at y 11717. `background = #e0e0e0` written in place: the read of the scratch reader that started 627 ms after the command and ended at 673 ms has the selected row as the last row in view, at `1055.0,706.0 260.0x24.0`. A `rows` read of the script after it (52.2 s): 472 `theme` lines, `theme Zenwritten Light marks=Dark selected=1 frame=1055.0,706.0 260.0x24.0 id=file:Zenwritten Light`, `list frame=1055.0,403.0 260.0x327.0`. **Third run** (`42d6641`): 464 file themes, `Zenwritten Light` a copy and applied to Dark. **A second open** in launch 3C: `Zenwritten Light marks=Dark selected=1 frame=1055.0,706.0 260.0x24.0 id=file:Zenwritten Light`, the last of the 14 rows in view, in `list frame=1055.0,403.0 260.0x327.0`. **A first open in a launch** (launch 3D; the first snapshot has `file:Zenwritten Light`): the same line. **A second open** in launch 3D: the same line. The run did not scroll before any of the three. **Then** two `wheel` calls: the first row at `1055.0,413.0`, the selected row at y 11717. `background = #e0e0e0` written in place: the read of the scratch reader that started 522 ms after the command and ended at 726 ms has the selected row as the last row in view, at `1055.0,706.0 260.0x24.0`. A `rows` read of the script after it (35.8 s): 472 `theme` lines, `theme Zenwritten Light marks=Dark selected=1 frame=1055.0,706.0 260.0x24.0 id=file:Zenwritten Light`. | pass, in the three runs |
| **S63** A name of 200 letters | A file named with 200 times `W`, with the Dracula text. `show "file:<200 W>"` prints `shown <200 W>`; `apply Dark on`: the snapshot's `name` has 205 characters. The window closed and opened: `window frame=847.0,250.0 873.0x530.0`, the frame of S44. All 36 frames that `rows` prints lie inside it; the showcase's title is `1327.0,412.0 235.0x19.0` and its caption `1568.0,415.0 121.0x16.0`. `rows` prints `theme <200 W> marks=Dark selected=1 frame=1055.0,605.0 260.0x24.0 id=file:<200 W>` and `showcase title=<200 W> caption=dark theme, from a file`, each with all 200 letters. In the capture the row's title is cut with an ellipsis and its mark *Dark* is whole (the label `Dark` is `1264.0,610.0 34.0x14.0`, inside the row); the showcase's title is cut with an ellipsis and the caption *dark theme, from a file* is whole. `app-prefs.json` is `{"warn_before_quit":true,"theme_dark":"file:<200 W>"}` with all 200 letters. **Second run** (launch 2A): every line and every frame above is the same, value for value: the window `847.0,250.0 873.0x530.0`, 36 frames inside it, `list frame=1055.0,403.0 260.0x327.0`, the row at `1055.0,605.0 260.0x24.0` with its whole title and id, the title `1327.0,412.0 235.0x19.0`, the caption `1568.0,415.0 121.0x16.0`, the mark `1264.0,610.0 34.0x14.0`, the capture with the two ellipses and the whole mark and caption, and the whole id in `app-prefs.json`. **Third run** (`42d6641`): every line and frame is that of the first run: the window `847.0,250.0 873.0x530.0`, 36 frames inside it, `list frame=1055.0,403.0 260.0x327.0`, the row `frame=1055.0,605.0 260.0x24.0` with its whole title and id, the title `1327.0,412.0 235.0x19.0`, the caption `1568.0,415.0 121.0x16.0`, the mark `1264.0,610.0 34.0x14.0`, and the whole id in `app-prefs.json`. The capture of the window is the capture of the first run, pixel for pixel: 0 of 462 690 pixels differ. | pass, in the three runs |

### S54, part by part

Launch C in the first run, launch 2B in the second and launch 3C in the third: a fresh channel
whose folder held the 463 links before the launch (`ln -s` for each file of
Ghostty 1.3.1), and nothing more.

| Part | First run | Second run | Third run (`42d6641`) |
| --- | --- | --- | --- |
| The count and the order | Snapshot: 471 ids in `available`, `"refused":[]`. `rows`: 471 `theme` lines; the ids of the lines are the snapshot's `available`, in order. The 463 file lines are in the order of the titles with no regard to letter case (`0x96f`, `12-bit Rainbow`, `3024 Day`, … `Zenburned`, `Zenwritten Dark`, `Zenwritten Light`): the same order as a sort of the 463 file names by their lower-case form. `files 463 themes from files.`, `files-help ` empty. | The same: 471 ids, 471 lines, the same order, the ids of the lines are `available`, `files 463 themes from files.`, `files-help ` empty. | The same: 471 ids, 471 lines, the ids of the lines are `available`, the order is that of the sort (`0x96f`, `12-bit Rainbow`, `3024 Day` … `Zenburned`, `Zenwritten Dark`, `Zenwritten Light`), `files 463 themes from files.`, `files-help ` empty. |
| The window, the list and the button | `window frame=847.0,250.0 873.0x530.0`, `list frame=1055.0,403.0 260.0x327.0`, `button Open Themes Folder frame=1569.0,739.0 132.0x22.0`: the three frames of S44. | The same three lines, which are those of S44 in launch 2A. | The same three lines, which are those of S44 in launch 3A. |
| The window opens | The first line is `theme Breeze Light … frame=1055.0,379.0 260.0x24.0`, above the list's top edge at y 403; the selected row, Breeze Dark, is at y 403 (see *Found on the way*). | At the first open of the launch: `theme Breeze Light marks=Light selected=0 frame=1055.0,413.0 260.0x24.0`, the y it has with eight rows; `theme Breeze Dark marks=Dark selected=1 frame=1055.0,437.0`; 14 rows in view by Accessibility, from Breeze Light to `Abernathy`, 13 of them whole. At a second open (`key 13`, `open`): the same two frames. | At the first open of the launch: Breeze Light at `1055.0,413.0`, Breeze Dark selected at `1055.0,437.0`; 14 rows in view, from Breeze Light to `Abernathy`, 13 of them whole. At a second open: the same two frames. |
| The list scrolls | After `wheel 1185 566 -40` the first line is at `1055.0,59.0` (it was at y 379). The window's frame, the list's frame and the button's frame are the same. 14 rows are in view by Accessibility, 13 of them whole. | After the same `wheel` the first line is at `1055.0,93.0` (it was at y 413). The three frames are the same. | After the same `wheel` the first line is at `1055.0,93.0` (it was at y 413). The three frames are the same. |
| A row out of view | `rows` prints all 471 lines, also for rows that are not in view (y from 379 to 11 659). `show "Hot Dog Stand"` selected its row, at y 4907, with no scrolling by the run: status 0, `shown Hot Dog Stand`, after 12 s. | The same, with the row at y 4941, after 32 s. | The same: all 471 lines (y from 413 to 11 693); `show "Hot Dog Stand"` selected its row at y 4941, after 30 s. |
| *Hot Dog Stand* | `showcase title=Hot Dog Stand caption=dark theme, from a file`, `note 3 terminal colours have low contrast on the background. 2 chrome colours have low contrast.`, and a `note-help` of nine parts: `ansi 7`, `ansi 15` and `foreground` on the background, and `text` and `muted` on each of `bg0`, `bg1`, `bg2`. | The same `showcase` and `note` lines (read with the scratch reader). | The same `showcase` and `note` lines, and with `rows` of the script the same `note-help` of nine parts, with the ratios of the first run: 2.46, 2.46 and 4.20 on the background; 4.49, 4.35 and 3.94 for `text` and for `muted` on `bg0`, `bg1`, `bg2`. |
| A snapshot is answered | With 471 ids, in 108 ms and 110 ms; each time holds the two calls of the run's clock, about 30 ms each. | In 106 ms, the same way. | In 109 ms, the same way. |
| The launch time | From the call of `make run` to the first snapshot, on a fresh channel each time. With no theme file: 4159 ms (launch A, the first of the run), 3545, 2309, 2833, 2505 ms. With the 463 links: 2739, 2583, 2447, 2505 ms. The medians are 2833 ms and 2544 ms. The largest time with the links is 430 ms over the smallest with no file, and under the median with no file. The time holds the no-op `cargo build` and `swift build` of `make run`, which is most of its spread. | One launch of each: 3062 ms with no theme file (launch 2A), 3005 ms with the 463 links (launch 2B). | With no theme file: 3178 ms (launch 3A), 3059, 2316, 2320 ms. With the 463 links: 2639, 2637, 2663 ms (the last is launch 3C). The medians are 2690 ms and 2639 ms. The largest time with the links is 347 ms over the smallest with no file. |
| A file added while the list is scrolled | The list scrolled as above (first row at y 59). `show "file:Andromeda"`, a row in view: selected, at `1055.0,611.0`. The file `Aaa` with the Dracula text written: a snapshot has 472 ids, and the scratch reader has `rows=472` in the read that started 504 ms after the command and ended at 547 ms. Then: the selected row is `Andromeda … selected=1 frame=1055.0,635.0 260.0x24.0 id=file:Andromeda` (24 points lower: `Aaa` is above it, between `3024 Night` and `Aardvark Blue`); the first row is still at `1055.0,59.0`, not at y 413 and not at y 379; `files 464 themes from files.` A full `rows` after it: 472 `theme` lines, `theme Aaa … frame=1055.0,347.0 … id=file:Aaa`, the same selected row and the same first frame. | The list scrolled as above (first row at y 93). `show "file:Andromeda"`: selected, at `1055.0,645.0`. `Aaa` written: the scratch reader has `rows=472` in the read that started 474 ms after the command and ended at 518 ms. Then: `Andromeda … selected=1 frame=1055.0,669.0 260.0x24.0 id=file:Andromeda`, in view (the list is from y 403 to y 730); the first row is still at `1055.0,93.0`, not at y 413; `files 464 themes from files.` A full `rows` of the script after it (52.0 s): 472 `theme` lines, `theme Aaa … frame=1055.0,381.0 … id=file:Aaa`, `theme Andromeda marks= selected=1 frame=1055.0,669.0 …`, `theme Breeze Light … frame=1055.0,93.0`. | The first row at y 93. `show "file:Andromeda"`: selected, at `1055.0,645.0`. `Aaa` written: the scratch reader has `rows=472` in the read that started 618 ms after the command and ended at 661 ms. Then: `Andromeda … selected=1 frame=1055.0,669.0 260.0x24.0 id=file:Andromeda`, in view; the first row still at `1055.0,93.0`; `files 464 themes from files.` A full `rows` of the script after it (34.7 s): 472 `theme` lines, `theme Aaa … frame=1055.0,381.0 … id=file:Aaa`, the same selected row and first frame. |
| The time of `rows` and of `show` | `rows`: 98.6 s, 145.3 s and 100.5 s. `show`: 12 s, 39 s and 48 s. | `rows`: 50.2 s, 52.7 s, 52.0 s and 52.2 s. `show`: 32.2 s by a title; 24.8 s, 28.2 s and 8.1 s by an id. With eight rows `rows` took 0.3 s. So the "within 2 s" clause was timed with the scratch reader again, and each number above says which reader it came from. | `rows`: 33.8 s, 37.8 s, 34.7 s and 35.8 s. `show`: 30.3 s by a title (row 203); by an id 19.5 s (row 24), 21.3 s (row 204) and 55.5 s (the last row, 472). With eight rows `rows` took 0.3 s. The "within 2 s" clauses were timed with the scratch reader again. |

### The scenarios of 2610.0008 (S61)

Run in launch A. The whole-object comparisons read `choice`, `in_effect`
and `name`, as *What this changes in 2610.0008* says.

| Scenario | Observed | Result |
| --- | --- | --- |
| **S33** The pane, with the new frame | Fresh channel, the Mac Light, ⌘,: `pane=Fonts`. `pane Theme`: `pane=Theme`; the capture shows the row *Appearance* with the three tiles, and under it the list and the showcase, and under them the line about the files and the button. Eight `theme` lines in the order of the catalogue; `marks=Light` on Breeze Light, `marks=Dark` on Breeze Dark and selected, none on the other six. `showcase title=Breeze Dark caption=dark theme`, `box Apply to Light value=0 enabled=1`, `box Apply to Dark value=1 enabled=0`, `note 5 terminal colours have low contrast on the background.` The frame is `847.0,250.0 873.0x530.0` on both panes, also after two more changes each way: not less than 691 × 299, and 42 points taller than the 873 × 488 of `17b54fe`. `resizable=false`. All frames inside the window (17 and 34). The eight rows are from y 413 to y 605, all in view. **Third run** (`42d6641`): the same lines: `pane=Fonts` at the first open, the eight `theme` lines, the same marks and selected row, the same `showcase`, two `box` and `note` lines; `847.0,250.0 873.0x530.0` on both panes after each change; `resizable=false`; 17 and 34 frames inside; the eight rows from y 413 to y 605. | pass, in the first and the third run |
| **S35** Breeze Dark to Catppuccin Mocha | The board with a terminal, a doc and an HTML card. `show "Catppuccin Mocha"`, `apply Dark on` (`value=1 enabled=1`, status 0), no restart. `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}`. File `{"warn_before_quit":true,"theme_dark":"catppuccin-mocha"}`. Five `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. `marks=Dark` on Catppuccin Mocha, none on Breeze Dark, `box Apply to Dark value=1 enabled=1`. **Third run** (`42d6641`): the same `shown` and `box` lines, snapshot and file. Five `11111b`, `313244`, `1e1e2e`, `181825`, `181825`. `marks=Dark` on Catppuccin Mocha, none on Breeze Dark. | pass, in the first and the third run |
| **S44** A light theme while the choice is *Dark* | Before: Breeze Dark five, file `{"warn_before_quit":true}`, pictures *Auto* `e3e5e7` at the left and `24282c` at the right, *Light* `e3e5e7`, *Dark* `24282c`. `show "GitHub Light"`, `apply Light on`. After: the same snapshot; the same five; 0 of the 2 921 000 pixels of the main window differ; file `{"warn_before_quit":true,"theme_light":"github-light"}`; `marks=Light` on GitHub Light, none on Breeze Light, `marks=Dark` on Breeze Dark, `tile Dark value=1`. *Light* picture `eaeef2`; *Auto* `eaeef2` at the left and `24282c` at the right, its left half the left half of the *Light* picture, pixel for pixel, and 0 pixels of its right half differ; 0 pixels of the *Dark* picture differ. **Third run** (`42d6641`): the same: the snapshot and the five did not change, 0 of the 2 921 000 pixels of the main window differ, file `{"warn_before_quit":true,"theme_light":"github-light"}`, the same marks, `tile Dark value=1`; *Light* `eaeef2` (it was `e3e5e7`), *Auto* `eaeef2` and `24282c`, its left half the left half of *Light* pixel for pixel, 0 pixels of its right half and of *Dark* differ. | pass, in the first and the third run |
| **S45** The *Light* tile | `theme Light`: `{"choice":"light","in_effect":"light","name":"github-light"}`. Five `eaeef2`, `e1e6eb`, `ffffff`, `f6f8fa`, `f6f8fa`. The same marks, the same two `box` lines (`Light value=1 enabled=1`, `Dark value=0 enabled=1`) and the same selected row, GitHub Light. The three pictures, on the inner 62 × 40 pixels of each: 4 pixels differ, by 1, in each. **Third run** (`42d6641`): the same snapshot, five `eaeef2`, `e1e6eb`, `ffffff`, `f6f8fa`, `f6f8fa`, the same marks, boxes and selected row. The three pictures: 4 pixels differ, by 1, in each. | pass, in the first and the third run |
| **S51** The file cannot be saved | Breeze Dark in effect, file `{"warn_before_quit":true,"theme_light":"github-light"}`, the channel directory made mode 555. `show "GitHub Dark"`, `apply Dark on` (status 0): `"name":"github-dark"`; five `010409`, `161b22`, `0d1117`, `070a10`, `070a10`; `marks=Dark` on GitHub Dark; one `tarmac: could not save app prefs: … Code=513 …` line on stderr where there was none; the file's SHA-1 and modification time are the same; the same two windows; the same pid. The directory was then made mode 755. **Third run** (`42d6641`): the same: `"name":"github-dark"`, five `010409`, `161b22`, `0d1117`, `070a10`, `070a10`, `marks=Dark` on GitHub Dark, one `could not save app prefs` line where there was none, the same SHA-1 and modification time, two windows, the same pid. | pass, in the first and the third run |
| **S53** A selected row changes nothing, and the locked box | **First part**, Mocha saved and in effect: after `show` of each of the eight titles the file's modification time and SHA-1 are the same, the snapshot is `{"choice":"dark","in_effect":"dark","name":"catppuccin-mocha"}`, and the five are those of Mocha. **Second part**, the fresh channel: eight `show` calls, each status 0, no `app-prefs.json` after each. **Third part**, Breeze Dark shown: `box Apply to Dark value=1 enabled=0`, `box Apply to Light value=0 enabled=1`. `apply Dark off`: status 1, last line of stdout `box Apply to Dark value=1 enabled=0`. `apply Dark on`: status 1, the same line. `apply Light off`: status 1, `box Apply to Light value=0 enabled=1`. Breeze Light shown (`box Apply to Light value=1 enabled=0`), `apply Light off`: status 1. After the four: no `app-prefs.json`, `{"choice":"dark","in_effect":"dark","name":"breeze-dark"}`, `marks=Light` on Breeze Light and `marks=Dark` on Breeze Dark. **Third run** (`42d6641`): the same in the three parts: after each of the eight `show` calls the same modification time, SHA-1, snapshot and Mocha five; on the fresh channel no `app-prefs.json`; the four commands end with status 1 and the same last lines; after them the same snapshot and marks. | pass, in the first and the third run |
| **S70** The script tells the two tables apart | *Theme*, Breeze Dark shown: `pane=Theme`. `pane "Breeze Dark"`: status 1, `the sidebar lists ["Fonts", "Theme"] and none is Breeze Dark`, still `pane=Theme`. `show Fonts` and `show Sepia`: status 1 each, `the list of themes holds [the eight titles] and none is Fonts` (and `Sepia`); the selected row is still Breeze Dark. `pane Fonts`: `pane=Fonts` and no `theme`, `showcase`, `picture`, `box`, `note`, `list`, `files` or `button` line. `pane Theme`: the eight `theme` lines and the others again. **Third run** (`42d6641`): the same statuses, messages and lines; 0 lines of the Theme pane on *Fonts*, and 8 `theme` lines and the 10 others on *Theme* again. | pass, in the first and the third run |

## Found on the way

- **The list is not eight rows high (first run: reported as a defect).** The contract says of the list:
  "Its height is that of eight rows, at all times" (G17). `rows` prints
  `list frame=1055.0,403.0 260.0x327.0` with no theme file, with one, and
  with 463. A row is 24 points, so the list has room for 13 rows and part
  of a 14th, and the capture with 463 files shows 13 whole rows. With eight
  themes the list has an empty part under its last row. The size of the
  window and the frame of the button are the same in every state, which is
  what S44, S54 and S63 test, and they pass.
  **After the first run** the spec was changed (*Changed after the gate*):
  the list is as tall as its column of the box, and not less than eight
  rows. The second run has the same line, `list frame=1055.0,403.0
  260.0x327.0`, with no file (launch 2A), with one file, with 463 and with
  464. 327 points is more than the 192 points of eight rows. By the new
  text this is no defect.
- **With a long list, the window opens with the first row out of view
  (first run: reported as a defect).**
  Launch C, Breeze Dark selected (the second row), 471 or 472 rows: at each
  `open` the first row, Breeze Light, is at y 379, above the list's top
  edge at y 403, and the selected row is the first row in view, at y 403.
  It was the same at three openings. With eight or nine rows the first row
  is at y 413. The selected row is in view, as G22 asks. But Breeze Light
  is hidden until the user scrolls up, and the user has no sign that a row
  is above.
  **After the fix** (`ThemeList` scrolls after the layout, and only as far
  as the row needs), second run, 471 rows, Breeze Dark in effect: at the
  first open of a launch and at a second open, Breeze Light is at y 413
  and Breeze Dark at y 437, as with eight rows. With the last file theme
  in effect (S62) the selected row is in view at a second open, at the
  first open of a launch and at a second open of that launch, and again
  after a change of the file. After a change of the themes with the list
  scrolled (the `Aaa` part of S54) the selected row stayed in view and the
  list kept its place.
- **A list that was scrolled before the window was closed opens with the
  first row out of view (second run; the spec records it as a limit).** Not in a scenario.
  471 rows and `Aaa`, Breeze Dark in effect, the list scrolled so that its
  first row was at y 93. `show "file:Zenburned"` selected a row near the
  end, at y 11349, out of view; the showcase had Zenburned. The window was
  closed (`key 13`) and opened (`open`). Then: the showcase and the
  selected row are Breeze Dark, the theme in effect, as the spec says for
  an open; that row is in view, as the first row in view, at
  `1055.0,403.0 260.0x24.0`; Breeze Light is at y 379, above the list's
  top edge. So the theme in effect is in view. The list keeps its scroll
  place while the window is closed and then moves only as far as the row
  needs, which puts the row at the top edge. This is what the fix says it
  does. What the user sees is what the first run found: the selected row
  at the top, and a row above it that does not show.
- **`rows` and `show` are slow with hundreds of rows (a limit of the
  script).** `rows` took 99 s to
  145 s with 471 rows, and `show` 12 s to 48 s. With nine rows `rows` takes
  0.1 s to 0.3 s. The script walks the whole window again for each named
  part and for each row. So the script cannot time "within 2 s" for a long
  list. The script was not changed. A scratch reader that asks the table
  for `AXRows`, `AXSelectedRows` and `AXVisibleRows` took less than 1 s.
  **After the change of the script** (it reads the window once for a run),
  second run, 471 and 472 rows: `rows` took 50.2 s, 52.7 s, 52.0 s and
  52.2 s; `show` took 32.2 s by a title and 8.1 s to 28.2 s by an id. That
  is about two times as fast for `rows`, and it is still too slow to time
  2 s. The scratch reader was used again for those clauses. The cost that
  is left grows with the count of rows: with eight rows `rows` took 0.3 s.
- **A theme that comes back is in effect again, but is not shown again.**
  S49 and S50. While the file was no theme, the selected row and the
  showcase went to Breeze Dark, the theme in effect. When the file was a
  theme again, Dracula was in effect and had its mark, and the selected row
  and the showcase stayed on Breeze Dark. This is the rule of
  `ThemeBrowser.shown`: a shown theme that the library still has is kept.
- **A daemon of an earlier run was alive at the start.** Pid 9018, a debug
  `tarmacd`, held `.dev/qa-218/tarmacd.sock`, and the directory
  `.dev/qa-218` did not exist. `make kill-daemon` cannot find a daemon
  whose socket file is gone (`lsof` needs the path). It was stopped by that
  pid, after `lsof -p 9018` showed that socket. For a later run: stop the
  daemon before the channel directory is removed.
- **A capture by window id can hold a second window.** The indicator of the
  input source is a small window of the app near the caret. When the
  terminal card was partly out of the window, the indicator was 6 points
  outside the main window's frame, and the capture was 2546 pixels wide in
  place of 2540: every point was 6 pixels off. The run checks the width of
  each capture. The values of S47 were sampled again after the board was
  moved.
- **The times.** The first report of a change came 26 ms to 547 ms after
  the command. The times for a second change soon after a first were short
  (26 ms, 43 ms, 136 ms); the others were 147 ms to 420 ms by a snapshot.
- **The doc card is at its top after a relaunch.** `scroll.offset` of
  `theme-doc.md` was 400 before the quit of S51 and 0 after the launch. No
  scenario of this spec asks for it, and it is not a matter of the theme.
- **Another app came to the front one time.** During launch B the front
  app was Microsoft Edge for some seconds and the dev app had no window on
  screen. One call that sets the window's size failed and was run again.
  No capture and no pointer event was made in that time.
- **Third run: the main window comes on the display of the front app.**
  In the first two runs the main window came on the 1× display. In every
  launch of the third run it came on the second display, at
  `2910.0,139.0`, in the middle of that display's width. The front app of
  the Mac (a browser) had its windows there. A scratch window that took
  the key status on the 1× display before the launch did not change it.
  The run moved the main window before each sample. A capture by window id
  of a window on the 2× display has two pixels for a point, and its
  colours differ by 1 from the values of the 1× display (`25282c` for the
  board `24282c`). No scenario of this spec is about the place of the
  window.
- **Third run: two recorders at one time do not record.** To have S51 on
  whichever display the window came, two `ffmpeg` processes were started,
  one for each display. The one for the 1× display wrote its file; the one
  for the second display wrote none and did not end, and a later recorder
  for that display did the same while the first was alive. The three
  processes were stopped by their pids (they did not end at `kill`, and
  were ended with `kill -9`). After that one recorder for the second
  display worked. So the app was started three times for S51, each time
  from the state of S46; each start had `"name":"file:Dracula"` in its
  first snapshot (3442, 2746 and 3995 ms after the call).
- **Third run: `show` is slower for a row far down the list.** The script
  now stops at the row whose id matches, and reads the rows before it. By
  an id: 19.5 s for row 24, 21.3 s for row 204, 55.5 s for the last row
  (472). In the second run the last row took 8.1 s. `rows` is faster than
  in the second run (34 s to 38 s for 50 s to 53 s). Both are still too
  slow to time 2 s on a long list.
  *After the third run* the script was changed for this: it read each
  row's texts before it compared the row's id. It now reads the ids
  first, and a title only when no id matches. Measured once after that
  change, by the session that made it, on a fresh channel with the 463
  files linked (471 rows): `show "file:3024 Day"` (row 9) 4.7 s,
  `show "file:Zenwritten Light"` (the last row) 11.6 s,
  `show "Catppuccin Mocha"` (by a title; it selects the built-in row)
  17.4 s, `show "Hot Dog Stand"` 11.9 s, a name that no row has 16.1 s
  with exit 1 and the line that lists every title, `pane Fonts` 3.6 s,
  and `pane Nope` exits 1 with `the sidebar lists ["Fonts", "Theme"]`.
  The app's code was not changed.
- **Third run: S60 changed more of the default channel's `state.json`.**
  After launch 3H, 112 doc cards of the default board have `"loose": true`
  where they had `false`, and the two terminals have new ids again;
  nothing more changed, and `.dev/app-prefs.json` is the same. `loose` is
  "not attached to the terminal that opened it". The daemon of the first
  run's S60 gave the two terminals new ids, so at this launch those docs
  had no terminal with the id they name. This is what a restart of the
  default channel's daemon does to that board; no code of this change
  reads or writes it. The file as it was before the first run and before
  the third run is kept outside the repository.
- **The Finder writes `.DS_Store`.** After S57 the config directory held a
  `.DS_Store` of the Finder. It was removed with the channel.
- **S60 changed two ids in the default channel's `state.json`.** The plain
  `make run` started a daemon for the default channel, which gave the two
  terminals of that board new ids. Nothing more of that file changed.
  `.dev/app-prefs.json` did not change.
- **The tiles of old S45 differ by 1 in 4 pixels.** The earlier record has
  a difference of 0. The window changed from dark to light between the two
  captures. It is inside the tolerance.

## After the referee

The referee of the spec ran after the second run and changed nothing. Its
findings were then mended in the tree. The changes that a live app can
show are three: the file's bytes are read through a file handle, to one
byte over the limit at most (`ThemeFolder`); the rule of a tooltip moved
from the pane to `ThemeBrowser.toolTip`; and `ThemeBrowser.shown` and
`ThemeLibrary.entry` ask one lookup, `ThemeLibrary.theme`. The other
changes are tests, comments and a name.

One short check was made on that tree, on a fresh channel, by the session
that mended it. It is not a third run of a scenario.

| Step | Observed |
| --- | --- |
| The folder is made with `Dracula` (the Ghostty 1.3.1 file), `broken` (`foreground = #fff` only) and `Big` (65,537 bytes) | The snapshot has `file:Dracula` as the last of `available`, and `refused` is `["Big: is larger than 64 KiB","broken: has no background"]` |
| `open`, `pane Theme`, `show file:Dracula`, `apply Dark on` | `shown Dracula`; `box Apply to Dark value=1 enabled=1`; the snapshot's `name` is `file:Dracula` and its `findings` is `["ansi 0 on background: 1.11 (floor 3)"]` |
| `rows` | `window frame=847.0,250.0 873.0x530.0`; `list frame=1055.0,403.0 260.0x327.0`; `theme Dracula marks=Dark selected=1 … id=file:Dracula`; `showcase title=Dracula caption=dark theme, from a file`; `note-help ansi 0 on background: 1.11 (floor 3)`; `files 1 theme from a file. 2 files were not read.`; `files-help Big: is larger than 64 KiB \| broken: has no background`; `button Open Themes Folder frame=1569.0,739.0 132.0x22.0` |

The window, the list and the button have the frames of S44. The app was
stopped by the pid of its driver socket and its daemon with
`make kill-daemon`, and the channel was removed. Nothing was made under
`~/.config/tarmac`.

## After the cleanup pass

A cleanup pass after the first commit (`e978a79`) was meant to change no
behaviour. An independent check of it found one change, in the commit
`dfa3d40`: a socket, and a folder or a pipe with no permission, were told
as "cannot be read". The next commit took that back. The check below was
made on `dfa3d40`, and has none of those three in its folder.
What a live app can show of the pass: `ThemeFolder` now reads through
`FileBytes.read(path:limit:)`, which replaces the file handle of the
section above; `ThemeFolderWatch` is a main-actor class; the pane has one
sequence for "the window opens" and "the themes changed"; and the QA
script walks each row once. One short check was made on that tree, on a
fresh channel, by the session that made the pass. It is not a run of a
scenario.

| Step | Observed |
| --- | --- |
| Launch with no config directory | `name` is `breeze-dark`, `available` has 8 ids, `refused` is `[]` |
| The folder is made with `Dracula`, `Nord` (a link to the Ghostty 1.3.1 file), `broken` (`foreground = #fff` only), `Big` (65,537 bytes), `Pipe` (a named pipe), `sub` (a folder) and `Dangling` (a link to nothing) | `available` ends with `file:Dracula`, `file:Nord`; `refused` is `["Big: is larger than 64 KiB","broken: has no background","Dangling: cannot be read"]`; the pipe and the folder give nothing, and the app goes on answering |
| `open`, `pane Theme`, `show file:Dracula`, `apply Dark on` | `shown Dracula`; `box Apply to Dark value=1 enabled=1`; the snapshot's `name` is `file:Dracula` |
| The file's `background` is changed in place to `#1e1f29`, then `rows` | `theme Dracula marks=Dark selected=1 … id=file:Dracula`; `showcase title=Dracula caption=dark theme, from a file`; `note-help ansi 0 on background: 1.04 (floor 3)` (it was 1.11); `files 2 themes from files. 3 files were not read.`; `files-help Big: is larger than 64 KiB \| broken: has no background \| Dangling: cannot be read`; `window frame=… 873.0x530.0`; `list frame=… 260.0x327.0`; `app-prefs.json` is `{"warn_before_quit":true,"theme_dark":"file:Dracula"}` |
| The file `Dracula` is removed | `name` is `breeze-dark`, `available` ends with `file:Nord`; the mark *Dark* and the selected row are on Breeze Dark; `showcase title=Breeze Dark`; `files 1 theme from a file. 3 files were not read.` |

The app's stderr held no line but the driver's. The app was stopped by the
pid of its driver socket, its daemon with `make kill-daemon`, and then the
channel was removed. Nothing was made under `~/.config/tarmac`.

## Not covered

- A bundled app, and the installed channel (`~/.config/tarmac`). The run
  wrote nothing there.
- A Mac that starts Dark. S56 ran on a light Mac, as it asks.
- A build of `17b54fe`: the frame of S44 and the `make qa` of S61 on it are
  from the spec and from the earlier record.
- A 2× display, and a display with another colour profile, but for the
  recording of S51 in the third run.
- The tooltips as the user sees them: they were read through
  Accessibility (`note-help`, `files-help`), not shown with a pointer.
- A file changed by an editor that saves in its own way (a safe save with
  a backup file), and a change of a file outside the folder that a link in
  the folder names.
- More than 464 files, and a folder on another volume.
- The five fills for a file theme on a second board and on a culled card:
  2610.0008 S42 has that for a built-in theme.
- The swatch of a file theme's row: no scenario samples it. In the
  captures each swatch shows its theme's colours.
- S51 with a light file theme, and the first frames of a new doc card
  under a file theme.
