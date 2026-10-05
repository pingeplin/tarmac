# QA — the font size setting (#206, spec 2610.0006)

The live half of [spec 2610.0006](../.blueprint/specs/2610.0006_font_size_setting.md):
its `[QA]` scenarios, with the values observed. The unit scenarios are
`FontSizeRuleTests`, `FontRoleTests`, `AppPrefsTests`, `FontCSSTests`,
`DocTemplateTests`, `TerminalViewTests` and `DevSnapshotTests`.

It is also the §1.3 exception-1 and exception-2 discharge for the shell the
change adds or touches: the size field and the stepper of
`SettingsWindowController`, `FontSettings.chooseSize`, `Theme.fontSizes`,
`TerminalView.fontsChanged`, `makeTerminalView`, `DocWebView.fontsChanged`,
`tarmacDoc.fonts`, the `--prose-size` property of `DocTemplate.html`, and the
snapshot reader.

The captures were read during the run and are not kept in the repository.
Where a row differs from its scenario's wording, the row says what was done.

**Run:** 2026-10-06, macOS 26.7, a `make run` debug build of the branch
`feat/206-font-size-setting` (on `c611aa7`), main display at 1×. The dev
channel started with no state: `board-0` with its boot terminal (470 × 330).
The input source was Zhuyin, and Keyboard navigation was on
(`AppleKeyboardUIMode` 2).

## What it uses

- `tarmac dev snapshot`'s `fonts` object, and `cards[].term.cols` / `rows`,
  `cards[].term.scrollback_tail`, `cards[].scroll.total`, `board_rect`,
  `focused_card`.
- [`font-settings-prose.md`](font-settings-prose.md), opened with
  `tarmac open` from a dev terminal, and
  [`scroll-indicator-white.html`](scroll-indicator-white.html) as the HTML
  card.
- [`scripts/qa/settings-window.swift`](../scripts/qa/settings-window.swift),
  with the verbs this change adds:
  - `rows` also prints each size field's value, accessibility label and
    frame, and the frames of the pop-ups, the steppers and the labels.
  - `size <n> <text>` sets a field's `AXValue` and performs `AXConfirm`,
    which sends the field's action as Return does.
  - `step <n> up|down` performs `AXIncrement` or `AXDecrement` on the
    `AXIncrementor`.
  - `focus <n>` sets `AXFocused` on a field. A field that takes the focus
    this way has all its text selected. A field that already has it keeps
    its caret, so each typed step first moved the focus to the other field.
  - `type <text>` and `press <key code>` post plain keys to the app's pid.
    They are how a text is left typed and not applied.
- Window lists come from `CGWindowListCopyWindowInfo` for the app's pid;
  captures from `screencapture -l <window id>`.
- `stty size` is typed with `tarmac dev type` after `tarmac dev focus`.
- The board is panned with the script's `wheel` verb over an empty point of
  the board, after `tarmac dev focus board` brought the dev window forward.
  A culled terminal is known by `tarmac dev focus <term>` answering
  `delivery: handling`.

## Checks

| Scenario | Observed | Result |
| --- | --- | --- |
| **S13** The window | No `.dev/app-prefs.json`. Pop-up frames: x 1137 and width 282 on all three rows. `AXTextField` 0: value `16`, label `Terminal font size`, on the right of the Terminal pop-up. `AXTextField` 1: value `14`, label `Document font size`, on the Document row. Two `AXIncrementor`s, on the same two rows; none on the Interface row. `Prompt and Powerline icons need a Nerd Font.` under the Terminal row. Snapshot: `terminal.size` 16, `document.size` 14, `interface` has `face` and `saved` only. | pass |
| **S14** Terminal 16 → 20, typed | Before: 44 × 14 in the 470 × 330 card. `20` typed (the field shows `20`, the snapshot still 16), then Return. After, no restart: `fonts.terminal.size` 20, `board_rect` 470 × 330 as before, 37 × 11, `stty size` prints `11 37`, file `{"warn_before_quit":true,"terminal_font_size":20}`. One stepper press up then gives 20.5, so the stepper stood at 20. The sample line's frame is 1137,389 282 × 18 before and after. | pass |
| **S15** One step up and down | System Default family, 16, grid 44 × 14. Up: field `16.5`, snapshot 16.5, file `…"terminal_font_size":16.5…`, grid 44 × 14 at 1× (columns unchanged, rows not higher). Down: field `16`, snapshot 16, grid 44 × 14, file `…"terminal_font_size":16…`. | pass |
| **S16** Document 14 → 18 | Markdown card 392 × 310: `scroll.total` 3401 → 5610. HTML card: 36000 before and after, its text the same in the capture. Snapshot `document.size` 18; file `{"warn_before_quit":true,"terminal_font_size":16,"document_font_size":18}`. Captures of the card made 700 high, at 18 and at 14: the heading, the prose and the code block are all larger at 18. | pass |
| **S17** Relaunch | Before the quit: 20 and 18, grid 37 × 11, `scroll.total` 5610. After the app's pid was ended and `make run` started again: snapshot 20 and 18, grid 37 × 11, `scroll.total` 5610, fields `20` and `18`. | pass |
| **S18** The family and the size are independent | Terminal `Monaco` at 20, then *System Default*: field `20`, `terminal` `{"saved":null,"size":20}`, file `{"warn_before_quit":true,"terminal_font_size":20,"document_font_size":18}`. Terminal `Monaco` at 20, then size 16: the pop-up selects `Monaco`, `saved` and `face` `Monaco`, file has `"terminal_font":"Monaco"` and `"terminal_font_size":16`. Document `Georgia` at 18, then *System Default*: field `18`, `saved` null, `size` 18, file has `"document_font_size":18` and no `document_font`. Document `Georgia` at 18, then size 14: the pop-up selects `Georgia`, `css` begins `"Georgia"`, file has `"document_font":"Georgia"` and `"document_font_size":14`. | pass |
| **S19** Other boards, a culled card, later cards | Sizes 16 and 14. `board-0`: a second terminal (⌘T), `stty size` `14 44`, then the board panned until `focus` on it answers `handling`. `board-1` (⌘K, ⌘N): terminal 44 × 14, `stty size` `14 44`, a copy of the prose fixture at `scroll.total` 3401. Back on `board-0`, Terminal 20 and Document 18. On `board-1`, no restart: 37 × 11, `stty size` `11 37`, `scroll.total` 5610. There, ⌘T: the new 470 × 330 terminal is 37 × 11. A second copy of the fixture opened with `tarmac open`: a 392 × 310 card with `scroll.total` 5610, the same size and total as the first (no resize was needed). Back on `board-0` the second terminal is still culled (`handling`); after `zoom 0.15` brings it into the window, `stty size` in it prints `11 37`. | pass |
| **S29** Typed text | From 16. `99` + Return: field `32`, snapshot 32, file 32. Stepper up: field `32`, snapshot 32, file's bytes the same. `abc` typed (the field shows `abc`), Return: field `32`, snapshot and file the same. `13.3` + Tab: field `13.5`, snapshot 13.5. `13.50` typed (the field shows `13.50`), Return: field `13.5`, snapshot and file the same. | pass |
| **S30** A refused size in the file | File written with the app not running: `{"warn_before_quit":true,"terminal_font_size":64,"document_font_size":"18"}`. After `make run`: sizes 16 and 14, fields `16` and `14`, grid 44 × 14, `scroll.total` 3401, the file's SHA-1 unchanged. `16` typed + Return: SHA-1 unchanged. One stepper press up then writes `{"warn_before_quit":true,"terminal_font_size":16.5}`. | pass |
| **S31** Keys in the field | The terminal selected in the main window, at its prompt after `clear`; its `scrollback_tail` saved. Settings key, `AXFocusedUIElement` the `Document font size` field (set with `focus`, not with Tab: see below). `1`, `8`, Return: `document.size` 18, `focused_card` the same, `scrollback_tail` identical byte for byte. Then right arrow, ⌘A, `1`, `4`, Return: 14. The control without ⌘A (right arrow, then `9`) gives `189` in the field, so ⌘A did select the text. `scrollback_tail` still identical. | pass |
| **S32** A program that redraws | `top` running in the 470 × 330 card at 44 × 14. Size 20: 37 × 11, and the capture shows `top` filling 11 rows of 37 columns with no stale cell. | pass |
| **S33** The zoom | Zoom 1, size 20: 37 × 11. Size 16, zoom 1.5: 44 × 14. Size 20 at zoom 1.5: 37 × 11. | pass |
| **S34** The Document range | From 14, Terminal 16. `30` + Return: field `24`, snapshot 24. Stepper up: field `24`, file's bytes the same. `9` + Return: field `10`, snapshot 10. Stepper down: field `10`, file's bytes the same. `terminal.size` 16 after each step. | pass |
| **S35** A text that is not yet applied | From 16, `18` typed, no Return: the snapshot still 16. ⌘W: the Settings window is off screen, the snapshot 18, file `…"terminal_font_size":18…`; opened again, the field shows `18`. From 16, `20` typed, no Return, the stepper pressed up with `AXIncrement`: field `16.5`, snapshot 16.5, file 16.5. The same with a real click on the stepper's upper half (the script's `click`): field `16.5`, snapshot 16.5, and the keyboard focus still in the field. | pass |
| **S37** The file cannot be saved | `.dev/` made read-only, Terminal 16 → 20: field `20`, snapshot 20, grids 37 × 11; one stderr line `tarmac: could not save app prefs: … Code=513 …`; the file's SHA-1 unchanged; the same two windows, no alert; the app runs on. | pass |

`make qa`, in an app that had not shown the Settings window: 27 of 27.

**Run again after the referee's pass**, on the build where the rule "a size
already in effect is not a change" is `FontSizeRule.choice` and not a line of
`FontSettings`: S29, S30, S34 and S35, each step as in its row, with the same
values. The file's SHA-1 was compared before and after each step that must
not write. `make qa` was not run again: the pass changed no code it reaches.

## Knockout

S29 and S35 were run again on a build with two lines of
`SettingsWindowController` taken out, then the lines were put back.

| Line taken out | With it | Without it |
| --- | --- | --- |
| `stepper.valueWraps = false` | a step up at 32 leaves 32 | a step up at 32 gives 8: field, snapshot and file |
| `window.makeFirstResponder(nil)` in `windowWillClose` | ⌘W with `18` typed applies 18 | ⌘W leaves 16 in the snapshot and the file, and the typed text is gone when the window opens again |

Both agree with the probes in the spec's Context.

## Found during the run

- **A real digit key goes through the input source.** With Zhuyin active,
  the key codes of `2` and `0` put `ㄉㄢ` in the field. Return then commits
  the composition, and a second Return puts the field back to `16`: the text
  is not a number. The script's `type` verb therefore posts each character
  on a key code no layout has, with the character in the event. A user with
  such an input source must switch to a Latin one to type a size, as in any
  number field; the stepper needs no typing.
- **Tab does not go from one size field to the other when Keyboard
  navigation is on.** The stepper is the next key view, so S31's "by Tab"
  was not possible on this Mac. The field was given the focus through
  Accessibility. Tab out of a field still ends its editing and applies the
  text (S29).
- **A real click on the stepper does not take the keyboard focus** from a
  field that is being edited, with Keyboard navigation on too. So the rule
  of S35 holds for a click as it does for `AXIncrement`.
- **The field's accessibility label is readable** as `AXDescription`. The
  two fields are `AXTextField` 0 and 1; their rows are 0 and 2.
- **Not run:** whether ⌘C or ⌃Return typed in the field is offered to the
  terminal selected in the main window. ⌘C would replace the clipboard of
  the Mac the run was made on. ⌘A, an Edit item like ⌘C, reached the field
  (S31).
