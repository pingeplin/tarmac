# QA — native wheel for HTML cards (#144, spec 2610.0002)

The live half of [spec 2610.0002](../.blueprint/specs/2610.0002_native_html_card_wheel.md):
its `[Q]` scenarios, each with the one-line knockout that must make it fail, the
by-hand `[H]` ones, and the gesture script's own checks (S26). The unit
scenarios are `CardWheelTests`, `CardZoomTests`, `DevSnapshotTests`,
`CardShimTests` and `CardHostMessageTests`.

It is also the §1.3 exception-2 discharge for the shell wiring the change adds —
`HTMLCardWebView`, `HTMLCardView`, `CardShieldView`, `DevSnapshotReader`.

## What it uses

- `qa/wheel-travel-probe.html` — paints its own `scrollX`, `scrollY`,
  `innerHeight`, `scrollHeight`, `#inner`'s `scrollTop`, the last scroll
  `target`, its `wheel` and `mousedown` counts and `document.compatMode`, one
  word and one value a line. `qa/wheel-travel-probe-reveal.html` is the same in reveal mode.
- `qa/scroll-band-control.html` — the same page scrolling itself by a
  fractional `scrollBy`: the positive control of the band check.
- `scripts/qa/wheel-gesture.swift` — posts one real gesture at a card. **It
  moves the cursor** for about half a second a call, and refuses unless the dev
  app's window is the top one under its aim. It also moves, presses and drags
  the pointer, for [`scroll-thumb-drag-qa.md`](scroll-thumb-drag-qa.md).

"Units" are the probe's numbers. Under magnify one unit is `zoom/3` pt on
screen, so 100 pt of wheel is `300/zoom` units; in reveal a unit is a point.

## Setup

```sh
make run                                   # in another shell
export TARMAC_DEV_SOCKET="$PWD/.dev/tarmac-dev.sock" TARMAC_SOCKET="$PWD/.dev/tarmacd.sock"
P="$PWD/qa/wheel-travel-probe.html"
env -u TARMAC_TERM_ID core/target/debug/tarmac open "$P"      # likewise the reveal probe and the control
```

- **Bring the probe to the middle of the board.** No verb pans, but a wheel
  over a card that is not selected does: with nothing selected
  (`tarmac dev focus board`), `swift scripts/qa/wheel-gesture.swift <any card in
  the window> --dx <n> --dy <m>` moves the board by ten times that. `tarmac dev
  zoom` keeps the viewport's centre, so a centred card stays under the aim at
  every zoom.
- **Shielded** is selected and not borrowed. `tarmac dev focus board` first — a
  press on a window that is not key selects nothing — then the script with
  `--select`. The script checks `focused_card` itself and exits 1 if the click
  did not take.
- **Borrowed** is `tarmac dev focus "$P"`. To un-borrow: zoom out until a live
  terminal is in the window, `tarmac dev focus <term>`, then
  `tarmac dev key <term> escape` until `cards[].borrowed` reads false.
- **Reading the numbers.** By eye, or off a `screencapture` of the card. Below
  zoom 1 the magnify probe's text is too small: its scroll position does not
  change with the board zoom, so read it at zoom 1 before the gesture and again
  after. A reload — `touch` the file — puts every number back to 0.
- **A knockout** is the named one-line change, a rebuild and a relaunch. Revert
  the line, never the file.

## Checks

| # | Scenario | Do | Pass | Knockout → must read |
| --- | --- | --- | --- | --- |
| S31 | the aim | nothing selected, zoom 1, `--select` | exit 0; the printed point is in the probe's body; `focused_card` is the probe | `DevSnapshotReader` reports the origin without `displayPoint` → the script refuses |
| S7 | travel, shielded | 10 × `--dy -10` at zoom 0.25, 0.5, 1, 1.728, 2, 3 | `scrollY` +1200 ± 12, +600 ± 6, +300 ± 3, +174 ± 1, +150 ± 1, +100 ± 1 | `wheelScale` returns 1 → +100 at each zoom |
| S8 | travel, borrowed | the same, borrowed | the same | `scrollWheel` hands `super` the event unconverted → +100 |
| S9 | carry | zoom 2, `--dy -1 --events 30` | +45 ± 1 | a fresh `CardWheel()` per event → +30 |
| S10 | notched | `--lines --dy -1 --events 3` at zoom 1, 2, 1.728 | +360, +180, +207–209 | the view always uses the point-delta fields → +120 at each |
| S11 | across | zoom 2, `--dx -10 --dy 0` | `scrollX` +150 ± 1, `scrollY` unchanged | only axis 1 is written → `scrollX` +100 |
| S12 | reveal | reveal probe, zoom 0.5 and 2, 10 × `--dy -10` | +100 ± 1 at both | `wheelScale` ignores `magnify` → +600, +150 |
| S13 | nested scroller | zoom 1, `#inner` under the aim | `target inner`, `inner` +100 ± 1, `scrollY` unchanged | the copy's `location` is `.zero` → `inner` unchanged |
| S21 | a cut gesture | zoom 2, `--events 5 --no-end`, then a whole gesture | +75, then +150 ± 1 | none: a regression check |
| S29 | reload, no residue | zoom 2; `touch`, `--dy -3 --events 1`; again | +4 each time | `loadDocument()` does not reset → +4, then +5 |
| S30 | at its limit | zoom 1, `scrollY` 0, 10 × `--dy 10` | `scrollY` 0; `viewport.cx`, `cy` unchanged | `BoardView.scrollWheel` pans → record `cy` either way |
| S22 | the shield holds | after every shielded gesture, one with `--select` | `mousedown 0`; `wheel` grew | `CardShieldView.hitTest` returns nil → `mousedown 1` |
| S32 | not selected, no wheel | nothing selected, 10 × `--dy -10`, no `--select` | `wheel`, `scrollY` unchanged; `viewport.cy` +100 ± 1 | `BoardWheel.route` gives `.card` over any card → `scrollY` +300, `cy` unchanged |
| S25 | no band | zoom 1.728, the probe scrolled 30 s with reversals, precise then `--lines`; the control in the same run | no white band on the probe; the control shows one | none: the control is the check |
| S26 | the script refuses | another app's window over the card; an unknown card; no socket; no app; no debug CLI | exit 1, one line, nothing posted, the cursor where it was | — |
| S27 | **[H]** a real trackpad | zoom 0.5 and 2: flick; cut a flick short (pointer off the body, or `⌃`) | it coasts and stops like a markdown card beside it; the next flick scrolls normally | — |
| S28 | **[H]** a real notched mouse | zoom 1 and 2: one slow notch | about a row, 40 pt (120 / 60 units); record the units | — |

## Record

**2026-10-03 — `perf/144-unified-card-scroll` @ `9174ca7` + working diff**, the
debug app from `make run`, macOS 26, one 2560 × 1440 display at 1×, the dev
window at (730, 189). Driven by `scripts/qa/wheel-gesture.swift`; numbers read
by OCR off captures of the probe. By Claude, no hand on the machine. S25, S26's
first case and the knockouts of S7, S8 and S10 are from a second run the same
evening, after a review found the first short of what the spec names.

| # | Observed | Knockout observed |
| --- | --- | --- |
| S31 | **pass** — exit 0; point (1270, 573), body x 1075–1465, y 435–713; `content_origin` (730, 221); the probe selected, not borrowed | `content_origin` (730, 1219) → exit 1, "not the top one at 1270,1571", nothing selected |
| S7 | **pass** — +1200, +600, +300, +174, +150, +100 | +100 at each of the six zooms (the pass value only at 3) |
| S8 | **pass** — +1200, +600, +300, +174, +150, +100, `borrowed` true | +100 at each of the six zooms, `borrowed` true |
| S9 | **pass** — +45 | +30 |
| S10 | **pass** — +360, +180, +207 | +120 at zoom 1, 2 and 1.728 |
| S11 | **pass** — `scrollX` +150, `scrollY` +0 | `scrollX` +100 |
| S12 | **pass** — +100 at zoom 0.5 (`innerHeight` 140) and at 2 (560) | +600, +150 |
| S13 | **pass** — the probe first scrolled by the script (`--dy -100 --events 24` at zoom 1) to `scrollY` 7200, where `#inner` spans 216–816 of the viewport's 840 units and the aim is at 420; then `target inner`, `inner` +100, `scrollY` +0 | nothing scrolled: `inner` +0, `scrollY` +0, `wheel` unchanged (the probe was brought to 7200 at zoom 3, where the scale is 1 and no event is rebuilt) |
| S21 | **pass** — +75, then +150 | — |
| S29 | **pass** — +4, +4 | +4, +5 |
| S30 | **pass** — `scrollY` 0 → 0, `wheel` 0 → 10, viewport unchanged | viewport unchanged too: WebKit keeps a wheel it does not use, so nothing reaches `BoardView.scrollWheel`. The scenario stands as a regression check |
| S22 | **pass** — `mousedown 0` through every run above and after a `--select` gesture | `mousedown 1` |
| S32 | **pass** — `wheel` 10 → 10, `scrollY` 0 → 0, `cy` +100.0 | `scrollY` +300, `wheel` +10, `cy` unchanged |
| S25 | **pass** — 340 region captures over 34.4 s of precise gestures and 340 over 36.2 s of notched ones, with reversals: none with a white row (225 and 175 caught the content moving). The control, in the same session: 30 of 30 captures unpainted | — |
| S26 | **pass** — another process's window over the card (a 240 × 160 window centred on the aim): exit 1, "the dev app's window is not the top one at 1270,573", cursor (1832, 668) before and after. The aim off every window (a card outside the dev window): the same refusal. An unknown card, an unset socket, a socket nothing answers on and a tree with no debug CLI built: exit 1 with one line each. A success prints the card, the point and one entry per event | — |
| S27 | **pass, by hand and informally** — on 2026-10-04 the user scrolled cards with a trackpad in the dev app (`feat/191-card-scroll-indicator` @ `41ea952`, which carries this change) and found it right. The two zooms and the cut flick were not each recorded | — |
| S28 | **outstanding** — no notched mouse on the machine; S10 posted real line events | — |

Two things the run found and fixed in the assets, not the app:

- The probe's readout first sat under the default aim and took the wheel
  itself, so S13 scrolled the window. It now has `pointer-events: none`.
- One-letter labels (`y 300`) did not survive OCR. Each line is now one whole
  word and one number.

S25's frame counter is not tracked (it needs PIL and numpy): the count above is
a one-time record, and the check as written is by eye.
