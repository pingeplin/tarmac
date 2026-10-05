# QA — the draggable scroll thumb (#193, spec 2610.0004)

The live half of [spec 2610.0004](../.blueprint/specs/2610.0004_draggable_scroll_thumb.md):
its `[Q]` scenarios, each with the one-line knockout that must make it fail. The
unit scenarios are `ScrollIndicatorTests`, `ScrollDragTests`, `CardHitTests`,
`BoardWheelTests`, `CardHostMessageTests`, `CardShimTests`, `DevSnapshotTests`,
`TerminalEngineTests` and `TerminalViewTests`.

It is also the §1.3 exception-2 discharge for the shell wiring the change adds:
`CardView.hitTest`, `ScrollThumbView`'s mouse and wheel handlers and its cursor,
`CardView+Scroll`'s drag and timer, the cursor router's word on the thumb,
`routeScroll`'s `onThumb`, the three scroll-to paths and the snapshot reader.

## What it uses

The setup, probe and fixtures of [`scroll-indicator-qa.md`](scroll-indicator-qa.md), plus:

- `tarmac dev snapshot`'s `cards[].scroll.thumb` — the thumb's rect beside
  `screen_rect`, or `null`.
- `scripts/qa/wheel-gesture.swift`, which now goes on after its wheel:
  `--then thumb` | `thumb:<x>,<y>` | `<x>,<y>` moves the pointer to the thumb
  (its middle, or that far from its top-left) or to a point of the body;
  `--press`, `--drag <dx>,<dy>` (`--steps`, `--step-ms`), `--release`;
  `--clicks <n>`; `--sample <ms>` and `--sample-last <ms>` read the snapshot
  after a step and print the thumb against the pointer; `--stay` leaves the
  pointer; `--key escape` types Escape at the app; `--events 0` posts no wheel.
  A call that ends with its press held leaves the pointer, and the next call
  goes on from there.
- A scratch copy of the long markdown fixture, for S29: its text is replaced
  under a held thumb.

**The cards** are 392 × 310 at zoom 1, the terminal resized to that, so the
thumb is 24 long and its free travel, `free`, 242. **A wheel that moves
nothing** is one notch toward the edge the content is at
(`--lines --dy 1 --events 1` at the top). **Without `--stay`** the script puts
the pointer back where it found it, so before any wait for `shown == false`
the pointer is moved off and left: `--events 0 --at center --stay`.

## Checks

| # | Scenario | Do | Pass | Knockout → must read |
| --- | --- | --- | --- | --- |
| S26 | the lag (run first) | each kind at its top: press on the thumb, (a) ten steps over `free / 2`, the snapshot asked for 50 ms after each (`--step-ms 0 --sample 50`), (b) sixty steps 16 ms apart, asked once 50 ms after the last (`--step-ms 16 --sample-last 34`) | every sample's `thumb.y` at the pointer less the grab, to a device pixel plus one unit of the content | none: a measurement. A failure switches the thumb to being drawn at the pointer |
| S15 | each kind follows | three drags a kind: `2 × free` up, `free / 2` down, `free` down; lines written to the terminal's tty after the last two; on the probe a press with no drag, and with a drag of 1 | `offset` 0; half of `total − visible`; `offset + visible = total`. The terminal's offset stays under new output after the middle drag and follows it after the last. No drag: 0; 1 pt: 198 ± 2 | a terminal's offset handed to no one, `tarmacDoc.scrollTo` setting nothing, `HTMLCardView.scroll(to:)` posting nothing → that kind's `offset` unmoved; a `grab` of 0 → the half overshoots by 5 % |
| S16 | the pointer holds | (a) pointer moved onto the showing thumb and left, then moved off; (b) the thumb moved from under a still pointer by a reload; (c) a release 100 below a thumb clamped at the track's end | (a) `shown` true and a thumb drawn at 3 s; false and none after the move off. (b), (c) `shown` false within 1.5 s, with no pointer move | (a) the router tells no card → false at 3 s; the timer left armed → `shown` true, no thumb drawn; no timer → `shown` false, thumb still drawn. (b) no ask after a layout, (c) none at the release → `shown` true 3 s later |
| S17 | a resting pointer | pointer left on a faded thumb; then a wheel that moves nothing there; then moved off | `shown` false; true 3 s after the wheel; false within 1.5 s of the move | no ask after a wheel → false within 1.5 s of the wheel; the router tells no card the pointer left → true 3 s after the move |
| S18 | the thumb beats the strip | thumb showing: press 1 pt inside its right edge (inside the resize strip), drag 50,50; the same with the thumb faded | showing: `offset` 9893 ± 1 %, `board_rect` unchanged. Faded: `offset` unchanged, `board_rect.w` + 50 | `CardHit.at` answers the handle first → showing, the card grows by 50 and `offset` stays |
| S19 | a wheel over the thumb | zoom 2: 10 × `--dy -2` at `--at 770,24`; zoom 1: the same at `--at 386,12`, on the thumb under the strip, the thumb held shown | `offset` + 30, + 60; the viewport unmoved | `onThumb: false` → `viewport.cy` + 9, `offset` + 3; the thumb hands its wheel to nothing → `offset` + 0 |
| S27 | nothing under it is pressed | (a) borrowed probe: press and drag on the thumb; (b) two presses, click states 1 and 2; (c) terminal running `cat -v` with mouse tracking on: a press on the showing thumb, and on the faded one | (a) the probe's `mousedown` unchanged, still borrowed; (b) not borrowed; (c) the tail unchanged, then a report with the thumb faded | `hitTest` passes `grabbable: false` → `mousedown` + 1, borrowed, a report in the tail |
| S28 | a drag cut short | press, drag `free / 4`, no release; `--key escape` until nothing is selected; a further drag and release | `shown` false at once; `offset` stays a quarter | a deselect does not drop the drag → `offset` a half |
| S29 | the thumb goes away under a press | held after a drag of `free / 4`: (1) the probe's file touched, a further `free / 4`; (2) on the scratch copy, the short text written over it, a drag, the long text back, a last drag; (3) the same, but the release posted while there is no thumb, then the long text back | (1) `offset` a half; (2) `offset` 0 with no thumb, then three quarters; (3) `shown` false within 1.5 s of the text's return, and 3 s later | (2) the card drops the drag when its thumb is not laid out → the last drag leaves `offset` 0; (3) the card's release monitor listens for the other button → `shown` true 3 s later |
| S30 | what stands | `make qa`; 2610.0003's S19, S28, S29, S30, S31 (reveal), S36 and S37 (zoom 1) again | as recorded in `scroll-indicator-qa.md` | — |
| S36 | the script refuses | `--then thumb --press --release` on the short fixture, nothing selected; `--drag`, and `--release`, with no press held | exit 1, one line, nothing selected | — |
| S37 | the cursor | captures with `screencapture -C`: on the markdown thumb over the strip, showing and faded; on the terminal's thumb and body | the arrow on a showing thumb; the resize cursor at the strip point once it has faded; the I-beam on the terminal's body | none: presentation |

## Record

**2026-10-05 — `main` @ `ebba168` + the staged diff**, the debug app from
`make run`, macOS 26, one 2560 × 1440 display at 1×. Driven by
`scripts/qa/wheel-gesture.swift`; numbers read off `tarmac dev snapshot`, the
probe's readout by OCR, thumbs and cursors off captures. By Claude, no hand on
the machine. `make test` and `make qa` (27 of 27) on that tree.

| # | Observed | Knockout observed |
| --- | --- | --- |
| S26 | **pass** — probe (840 of 48720), markdown (278 of 11484), terminal (11 of 2512 rows): in (a) the ten samples read the thumb −0.5 to +0.5 px from the pointer less the grab, and in (b) the one sample 0. Offsets at the end: 23940, 5603, 1251: half of each. Each snapshot was asked for 50 ms after its step's event and its read took 71 to 86 ms, so a sample is the thumb 50 to 136 ms after the step. Timed inside the app by a probe that is not shipped (the uptime at a drag event, and at the next thumb layout that moves it), ten steps 125 ms apart: 17 ms each on the probe, 8 to 17 on markdown, 5 to 17 on the terminal — a frame: that stepped series is the lag. In the run of sixty, 16 ms apart, the thumb moved on nearly every event (no more than 18 ms from the first unanswered event to its next move, but for one 34 on markdown), which is its cadence and not a bound on the lag. The thumb stays drawn from reports | — |
| S15 | **pass** — terminal, from its live bottom (1968, 11, 1979): 0; 984; twenty lines written to `/dev/ttys001` leave (984, 11, 1999); the end, (1988, 11, 1999); twenty more read (2008, 11, 2019). Markdown: 0; 5603; (11206, 278, 11484). Probe: 0; 23940; (47880, 840, 48720). No drag: 0; a drag of 1: 197 | terminal (2008, 11, 2019) unmoved; markdown 0 → 0; probe 0 → 0; `grab` 0: 26314, the half plus 2374 |
| S16 | **pass** — (a) `shown` true and a thumb drawn at 3 s; false inside the 1500 ms the wait allows, and none drawn, after the move off. (b) held at offset 7200, the thumb 36 down its track; touched: offset 0, the thumb back at the top, `shown` false 1245 ms later. (c) clamped at 47880; released 100 below: `shown` false 1218 ms after the script returned | (a) false and no thumb at 3 s; true and no thumb; false and the thumb still drawn. (b) true 3 s after the touch. (c) true 3 s later |
| S17 | **pass** — on the faded thumb `shown` false 1 s later; after the wheel true at 3 s, `offset` 0; moved off: false 1060 ms after the script returned | false within 1.5 s of the wheel; true 3 s after the move off |
| S18 | **pass** — showing: `offset` 9892, `board_rect` 392 × 310; faded: `offset` 9892, `board_rect` 442 × 310 | showing: `offset` 0, `board_rect` 442 × 310 |
| S19 | **pass** — zoom 2: 0 → 30; zoom 1 under the strip: 0 → 60; the viewport unmoved both times | `offset` 0 → 3 and `viewport.cy` + 9; `offset` 0 → 0, the viewport unmoved |
| S27 | **pass** — (a) `mousedown` 0 → 0 while `wheel` grew 4 → 7 and `scrollY` reached 11871; borrowed. (b) not borrowed, `offset` 0; the same two presses on the body borrow it. (c) the wheel is reported (`^[[<65;19;6M`); the press on the showing thumb leaves the tail; on the faded one it adds `^[[<0;37;11M^[[<0;37;11m` | (a) 0 → 1; (b) borrowed; (c) the tail gains the report with the thumb showing |
| S28 | **pass** — held at 11871 (60 of 242 of 47880: the drags were 60 pt, a quarter of `free` less half a point), `shown` true; one Escape: nothing selected, `shown` false in the first snapshot; the further drag and release leave 11871 | 23742, 120 of 242 |
| S29 | **pass** — (1) 11871; touched: `offset` 0, `total` 48720, `shown` true; then 23742. (2) 2778 (60 of 242 of 11206); the short text: `total` 278, `thumb` null, and the drag leaves `offset` 0; the long text back: `shown` true; the last drag: 8335 (180 of 242). (3) held at 2778; the short text; the release; the long text back: `shown` false 660 ms later and 3 s later, the thumb laid out at the top | (2) the last drag leaves 0. (3) `shown` true 3 s later — and also 3 s after a plain press, drag and release on the probe |
| S30 | **pass** — `make qa` 27 of 27. S19: the rule holds, a thumb at x 379–389, y 33–57 in the hold and none 2 s later. S28: `shown` false at +70 ms, no thumb at +421 ms. S29: 0 of 15 three times. S30: culled inside its hold, `shown` false and `thumb` null at +82 ms. S31: `null` in 2 of 120. S36: y 550–598 closed, 490–538 open. S37: x 379–389, 10 × 24, `#181b1d` and `#696b6c` on all four | — |
| S36 | **pass** — exit 1 each: "the card has no scroll thumb laid out"; "--drag needs --press, or a press an earlier call left held"; the same for `--release`. `focused_card` null | — |
| S37 | **pass** — the arrow on the markdown thumb over the strip and beside it, and on the terminal's thumb; the left-right resize cursor at the strip point with the thumb faded; the I-beam on the terminal's body | — |

S26 was first run with the script's own step wait ahead of the sample's, 66 ms
after each step; the row above is the run with the wait corrected, on the same
tree. S26 and S28 were also first run before the cursor router was wired, and
run again after it. The release moved off the thumb's view after the referee's
first pass (the last finding below): S15 on the probe, S16 (c), S18, S27 (b),
S28 and `make qa` were run again on that tree with the same outcome (S16 (c):
1103 ms), and so were the knockouts of S16 (c) and S28, whose lines it
rewrote.

Five things the runs found:

- **Escape had to come from the script.** S28 first deselected with
  `tarmac dev key <term> escape`. The click that selects the probe leaves the
  keys on the board, and that verb answers `not_focused`. The script now types
  it (`--key escape`). A card opened a moment before spends one Escape on its
  fresh mark first.
- **A hidden thumb is sent no drag event.** S29's first knockout made a drag
  event that answers nothing drop the drag, and the scenario still passed: of
  three drag events posted while the thumb was hidden, none arrived. They
  arrive again once it is laid out, so the drag picks up as specified. The
  knockout is now the card dropping the drag when its thumb goes away.
- **A wheel that shows the thumb is then dispatched to it.** S19's second
  knockout reads `offset` + 0, not the + 3 first predicted: the first event
  is routed to the body, shows the thumb, and lands on it like the rest.
- **A markdown card shows the arrow over its text**, so it has no I-beam to
  tell the thumb's arrow from. S37 takes that contrast from the terminal.
- **A hidden thumb is sent no release either.** The referee's first pass
  found it by a probe outside the app: a press let go while the thumb was not
  laid out — content that now fits, a reload, a cull — was never let go for
  the card, and the thumb then stayed shown. The card now reads the release
  off the application's events (S29's third case).

Reviewed, not run: the pointer leaving the window from a thumb, and a card
removed under a held thumb — nothing here can drive either.
