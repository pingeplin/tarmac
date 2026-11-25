# Markdown card sidebar state — manual QA (spec 2611.0024, #445)

Every [QA] scenario of `.blueprint/specs/2611.0024_doc_sidebar_state.md`. They are [QA]
scenarios because they test the shell wiring (D11–D14): a card seeded from its
tile, the layout written after a sidebar change, and both across an app restart
and a daemon restart. The rules are pinned by `DocSidebarTests`,
`LayoutTilesTests`, `BoardRestoreTests`, the conformance vectors and
`restore_integration.rs`. None of those runs the app.

**CAUTION: do NOT `pkill tarmacd`.** Run against `make run` only.

## Run 1

- **Build:** `6882fa0`, macOS 26.
- **Channel:** its own, `QA="$PWD/.dev/qa-sidebar"`. Before the first launch,
  `make kill-daemon DEV_DIR="$QA"` found no daemon on it. Every `make run` and
  `make kill-daemon` had `DEV_DIR="$QA"`. The CLI was
  `core/target/debug/tarmac` with `TARMAC_SOCKET` and `TARMAC_DEV_SOCKET`
  pinned to `$QA`.
- **Window:** the dev window opened on the built-in Retina display. After each
  launch it was moved and resized by pid with Accessibility to 2440 × 1129 at
  (60, 40), on the main display (scale 1). One screenshot pixel is then one
  point.
- **Board:** board-0. The boot terminal is at world (80, 80). Doc A (1280 ×
  360) is at (636, 80), B (1280 × 400) at (80, 450), C (392 × 310) at
  (−398, 80) and H (392 × 310) at (80, −270). Zoom is 1. The board was panned
  once by a wheel over the unselected terminal, so A, B and C fit in the
  window.
- **Docs:** A, B and C are three files. Each has front matter (`title`,
  `status`, `date`, `tags: [a, b, c]`, a block list `owners`), an h1, a
  paragraph, four h2 and one h3. H is a small HTML file.
- **Input:** presses, clicks and drags are real HID events from
  `scripts/qa/wheel-gesture.swift`. Before each one, `tarmac dev focus board`
  ran. The script also refuses to post unless the top window at the aim
  belongs to the dev app's pid.
- **Restore card:** it was up once, after the cold daemon of "Sidebar choices survive daemon restart with app down". It was
  closed with `press tab`, and `restore_card` read null before any click.
  Each quit was a held ⌘Q: `tarmac dev press cmd+q --hold 1500`.

**How the sidebar was measured.** A capture of the card's `screen_rect`
(`screencapture -R`), read along body row 270 (a blank row) by a pixel reader.
x is world px from the card body's left edge (capture x − 1).

| Mode | Panel colour `#353b41` | Line or border `#474e55` | Text area colour `#2b3036` |
|---|---|---|---|
| Docked at w | 0 to w − 1 | at w | after the line |
| Strip | 0 to 29 | none | from 30 |
| Overlay at w | strip and overlay together, 0 to w + 29 | at w + 29 | after the border |

**How `state.json` was read.** `$QA/state.json` was read only, never edited.
After each change it was polled every 100 ms until the key showed (5 s cap).
Each key showed on the first poll after the gesture script returned.

## Results

| Scenario | Result | Measured | Expected |
|---|---|---|---|
| Sidebar choices survive app restart | pass | **Before the quit:** A was docked at 240; after a grip drag of +60 it was docked at 300. B's `⇤` gave the strip (0–29). C (392): `≡` opened the overlay at 240 (border at 269); a grip drag of +40 gave 280 (border at 309). **`state.json` after the quit:** A `sidebar_w 300.0`, no `sidebar_open`; B `sidebar_open false`, no `sidebar_w`; C `sidebar_w 280.0`, no `sidebar_open`; H neither key. **After `make run`:** A docked at 300 (line at 300); B strip; C strip; C's `≡` opened the overlay at 280 (border at 309); B's `{}` docked it at 240 (line at 240) | A 300; B strip, then 240; C strip, then 280 (±2) |
| Sidebar choices survive daemon restart with app down | pass | First B was closed again (`⇤`, `sidebar_open false`). Quit; `state.json` as in "Sidebar choices survive app restart". `make kill-daemon` (pid 94685); `make run` started a new daemon; the restore card ("✓ 1 terminal back in its folder") was closed with Tab. Then: A docked at 300; B strip; C strip; C's `≡` opened the overlay at 280; B's `{}` docked it at 240 | as in S17 |
| Sidebar choices survive daemon restart with app up | pass | With the app up and A docked at 300: `make kill-daemon` (pid 7725). The app reconnected to the new daemon 9265, with no restore card. A was still docked at 300. A grip drag of −40 gave 260; `state.json` showed A `sidebar_w 260.0`. Quit and `make run`: A docked at 260 | 300 kept; then 260 |
| Collapse keeps the stored width | pass | A from 260: a grip drag of +40, and `state.json` showed `sidebar_w 300.0`. A drag of −200 from 300 and a release gave the strip (0–29); `state.json` showed `sidebar_w 300.0, sidebar_open false`. Quit and `make run`: A showed the strip; `≡` docked it at 300; `state.json` then showed `sidebar_w 300.0, sidebar_open true` | strip; then 300 |
| Closed and reopened doc starts fresh | pass | A was docked at 300 and its tile held `sidebar_w 300.0, sidebar_open true`. A click on its `✕` removed A's tile from `state.json`. Then `tarmac open` A (it came back at 392), and `tarmac dev resize` to 1280 × 360 (delivery `window`): docked at 240 (line at 240); A's tile was `{}`, with neither sidebar key, at w 1280 | 240; no keys |
| Narrow overlay is not kept across restart | pass | C (392, `sidebar_w 280`) had its overlay open by `≡` when the app quit in "Sidebar choices survive app restart". After `make run` it showed the strip, and its tile had `sidebar_w 280.0` and no `sidebar_open`. The same happened at the quit of "Sidebar choices survive daemon restart with app down" (overlay open, then the strip after the relaunch) | strip; `sidebar_w 280`, no `sidebar_open` |

## `make qa`

After "Narrow overlay is not kept across restart" the app was quit and a fresh `make run` started (no Settings window
shown in that process, #207). Then `make qa DEV_DIR="$QA"`
(`scripts/qa/smoke.mjs`):

- **Result: 33/33 checks passed.** Every `focus` and `resize` was delivered
  `window`, D4 and D5 included.
- **Skipped:** S21 ("the verb activates a non-frontmost app"), because no
  other app was in front when D12 ran. The suite reports it as skipped, not as
  passed.

## Teardown

The QA app was quit with a held ⌘Q. Then `make kill-daemon DEV_DIR="$QA"`
stopped daemon 9265. After that, no process held either QA socket.
`$QA/tarmacd.log` has no `ERROR` and no panic.

## Notes

- **The overlay grip** is right of the overlay's border line. A press at body
  x 268 (1 px inside the border at 269) did not start a drag; a press at 272
  did. The docked grip at the line (body x 240) took the press at 240. This
  slice does not change the page's grip, so this is not a finding.
- Every width above was the expected value exactly (0 px off); the spec's ±2
  tolerance was not needed.
