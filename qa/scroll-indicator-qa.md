# QA — the card scroll indicator (#191, spec 2610.0003)

The live half of [spec 2610.0003](../.blueprint/specs/2610.0003_card_scroll_indicator.md):
its `[Q]` scenarios, each with the one-line knockout that must make it fail. The
unit scenarios are `ScrollMetricsTests`, `ScrollIndicatorTests`,
`CardConsoleTests`, `HTMLCardSessionTests`, `CardHostScriptTests`,
`CardShimTests`, `DevSnapshotTests`, `TerminalViewTests` and
`TerminalEngineTests`.

It is also the §1.3 exception-2 discharge for the shell wiring the change adds:
`CardView`'s thumb, `ScrollThumbView`, the two web bodies' reports, the
terminal's mapping in `AppController`, the router's call and the snapshot
reader.

## What it uses

The probe pages and the gesture script of [`native-wheel-qa.md`](native-wheel-qa.md),
set up as that sheet says, plus:

- `qa/scroll-indicator-long.md` — 300 numbered paragraphs, then `END OF DOCUMENT`.
- `qa/scroll-indicator-short.md` — one line: content that fits its card.
- `qa/scroll-indicator-white.html` — 300 rows on a white page.
- `tarmac dev snapshot`'s `cards[].scroll` — `{offset, visible, total, shown}`
  or `null`. `--until 'cards[<id>].scroll.shown == true'` waits on it.

A wheel posted over a card that is not selected pans the board, which is how a
card is brought to the middle — and how one is culled (S30).

**Reading a thumb off a capture.** Two captures of the card, one inside the
hold and one two seconds later, differ only where the thumb is. Use a gesture
that moves nothing: toward the edge the content is already at. On a terminal,
compare only the columns right of the text, where the prompt does not blink.

**Timing.** The script returns about 220 ms after its last event (320 with
`--lines`), and the thumb is up for a second after that event. Where a check
has to land inside the hold, time the commands and record it.

## Checks

| # | Scenario | Do | Pass | Knockout → must read |
| --- | --- | --- | --- | --- |
| S16 | HTML metrics are the document's | probe, shielded, zoom 1: at the top, after 10 × `--dy -10`, at the end | `scroll` equals the `scrollY` / `innerHeight` / `scrollHeight` the probe paints; note its `compat` line | the shim swaps `visible` and `total` → `scroll` is `null` |
| S17 | terminal metrics are the engine's | a terminal with 300 lines and no wheel since launch; then `--select --lines --dy 3 --events 1` | `visible` = `term.rows`; `offset + visible = total`; then `offset` 3 less | the shell copies `total` into `offset` → `offset` does not change |
| S18 | markdown metrics are the scroller's | long fixture, zoom 1: at the top; then gestures to the end | `offset` 0, `visible` = the body's height on screen ± 1; at the end `offset + visible = total` ± 1 and `END OF DOCUMENT` shows | `doc-render.js` posts `scrollHeight` as `visible` → `visible` reads `total` |
| S19 | the rule, each kind | one gesture on a selected, overflowing card; then a second, with captures | `shown` true; still true 500 ms after the last event; then false. A thumb in the hold, none 2 s later; it starts 2 × zoom below the body's top at the top and ends 10 × zoom above its bottom at the end | the router does not tell the card → never `shown`; no timer → the thumb is still there at 2 s; no layout on new metrics → no thumb |
| S28 | deselecting hides it at once | a gesture, then `tarmac dev focus board` straight away | `shown` false and no thumb, both within 700 ms of the script's return | no reset → `shown` true; reset but the view left → `shown` false, thumb still drawn |
| S29 | what shows nothing | a gesture on the short fixture; `seq 1 500` in a selected terminal, no wheel; a gesture over the unselected probe | `shown` false in 15 snapshots over 1.5 s, each time | `laidOut` always true → the short card reads `shown`; a wheel on every metrics change → the terminal does; the router tells any card → the unselected probe does |
| S30 | a culled card | pan the probe 3000 pt away; then, selected and off-centre at zoom 0.25, a gesture and `tarmac dev zoom 3` at once | culled: `scroll` kept, `shown` false. Culled inside its hold: `shown` false, the probe still selected, within 700 ms | `laidOut` leaves out the hidden view → `shown` true while culled |
| S31 | a reload | probe at `offset` 300, `touch`; then the reveal probe off its top, `touch`, and the snapshot read about every 17 ms | `offset` 0, then `total` 48720 with `visible` 840; the reveal probe reads `null` on the way | `loadDocument()` sends no nil → the reveal probe never reads `null` |
| S35 | no WebKit root scrollbar | app started `-AppleShowScrollBars Always`; captures of the long fixture and the probe | no track, no gutter: the body's right edge is the page's own | (a) the template without `scrollbar-width: none` → a track; (b) the shim without its line → a gutter |
| S36 | the console | reveal probe, zoom 2, at its end; click the badge (`--select --at 683,-30 --dy 0 --events 1`), then `--lines --dy -1 --events 3` | the thumb ends 2 × zoom above the console; closed, 10 × zoom above the body's bottom | `scrollCover` answers 0, or its change is never announced → the thumb runs over the console |
| S37 | the look | captures at zoom 0.5, 1 and 2 of a terminal, a markdown page, the probe and the white page; the white page at zoom 0.2 | 10 × zoom wide, 2 × zoom in from the right edge of the body as it shows, clear of the corner; the colour at the thumb's middle and of its hairline the same on all four; a thumb at zoom 0.2 | the frame given a zoom of 1 → 10 wide at zoom 2; the fill given an alpha of 0.5 → one colour on the white page, another on the terminal; the frame given the body's whole container → no thumb at zoom 0.2 |
| S39 | the thumb takes no pointer | probe, zoom 2, at its top: `--at 770,24 --dy -2 --events 10` | `offset` +30 ± 1; the viewport does not move | the thumb answers its hit test → the board pans (`cy` +9 to 10), `offset` +0 |

## Record

**2026-10-03 — `feat/191-card-scroll-indicator` @ `5fbabdf` + working diff**, the
debug app from `make run`, macOS 26, one 2560 × 1440 display at 1×. Driven by
`scripts/qa/wheel-gesture.swift`; numbers read off `tarmac dev snapshot`, the
probe's readout by OCR, and thumbs off pairs of captures. By Claude, no hand on
the machine. Thumb boxes are in card points; a card is 392 × 310 at zoom 1, its
body's right edge at x 391 and bottom at y 309.

S31's reveal half and S37's colour knockout are from a second run on
2026-10-04, after a review made the thumb opaque, and a third laid the thumb
against the body as it shows. The thumb boxes of S19 and S37, S37's other two
knockouts and S39's pass (its knockout is the first run's) are from a fourth,
`74f1614` + working diff, after the user asked for a thumb 10 wide, not 6; the
terminal card was resized to the others' 392 × 310 for S37. `make qa` on that
tree: 27 of 27.

| # | Observed | Knockout observed |
| --- | --- | --- |
| S16 | **pass** — top: snapshot (0, 840, 48720), probe (0, 840, 48720). After one gesture: 300 and 300. At the end: 47880 and 47880. `compat BackCompat`: a card's document is in quirks mode | probe paints (300, 840, 48720); `scroll` is `null` |
| S17 | **pass** — rows 15; (389, 15, 404), `offset + visible = total`; after three lines (386, 15, 404) | (1197, 15, 1212) before and after: change 0 |
| S18 | **pass** — top (0, 278, 11484), body 310 − 32 = 278; end (11206, 278, 11484), sum − total = 0; the capture reads `Paragraph 300 of 300.` and `END OF DOCUMENT` | `visible` 11484 against a body of 278 |
| S19 | **pass** — on each kind `shown` → true, true 500 ms after the last event, → false. Thumb: markdown at its top x 379–389, y 33–57; at its end y 275–299. Probe at its top y 33–57; at offset 7800 y 72–96 (computed 72.4; the first run); at its end y 275–299. Terminal (600 × 400) at its live bottom x 587–597, y 365–389 | router silent: the wait for `shown` times out with the probe scrolled to 300. No timer: `shown` false at 2 s and the thumb still at y 33–57. No layout: the wait times out, no thumb in the capture |
| S28 | **pass** — `shown` false 47 ms after the script's return; the capture at 178 ms has no thumb | no reset: `shown` true at 53 ms. View left alone: `shown` false and the thumb still at y 33–57 at 151 ms |
| S29 | **pass** — short fixture (0, 278, 278): `shown` false in 15 of 15. Terminal printing, `total` 404 → 908: false in 15 of 15. Unselected probe, board panned `cy` +100: false in 15 of 15 | `laidOut` always true: true in 12 of 15. Wheel on every change: true in 14 of 15. Router tells any card: true in 11 of 15 |
| S30 | **pass** — culled (`focus` answers `card_hidden`, `screen_rect.x` −2656): `scroll` (300, 840, 48720), `shown` false; back and selected, a gesture shows it. Culled inside its hold: `focused_card` the probe, `scroll` not `null`, `shown` false, 64 ms after the script's return | `shown` true at 72 ms, the card culled |
| S31 | **pass** — (300, 840, 48720) → `offset` 0 → (0, 840, 48720). The reveal probe, 120 snapshots from the touch, four runs: (100, 280, 16240) → `null` in two → (0, 280, 16240), each time. The magnified probe: at zoom 1 `null` in one, then (300, 280, 48720), then (0, 840, 48720); at zoom 3 `null` in two, then (0, 840, 16240), then (0, 840, 48720) | three runs, `null` in none: (100, 280, 16240) → (0, 280, 16240) |
| S35 | **pass** — markdown: the page's background (48) in all 25 columns at the body's right edge. Probe: its rows (23) in all 25 | (a) eleven columns of track (46) inside the last 14. (b) a white gutter (177, 255, 255, 255) in the last four |
| S36 | **pass** — card 784 × 620: console open, thumb y 490–538, the console's top at 542; closed, y 550–598, the body's bottom at 618 | both knockouts: console open, thumb still y 550–598 |
| S37 | **pass** — markdown, probe and white page, each at its top: zoom 2, x 758–778, y 66–114 (20 × 48); zoom 1, x 379–389, y 33–57 (10 × 24); zoom 0.5, x 189–194, y 17–29 (5 × 12). The terminal, at its live bottom: the same x, and y 550–598, 275–299, 137–149. In all twelve captures, taken 81 to 131 ms after the script's return, the fill reads `#181b1d` and the hairline `#696b6c`, over pages of `#2b3036`, `#22303a`, `#ffffff` and `#31363b`. The white page far out: zoom 0.25, x 94–97 (3 wide); 0.2, x 75–77 of a card 78 wide, all hairline; 0.125, one pixel wide | zoom 2: x 770–780, y 64–88 (10 × 24). Fill at alpha 0.5 (the second run): `#8b8d8e` on the white page, `#24282c` on the terminal. The whole container: no thumb at zoom 0.2; at 0.5, x 190–195 |
| S39 | **pass** — `offset` 0 → 30, viewport unchanged, the probe's `wheel` count +10 | `offset` 0 → 0, `cy` +10, `wheel` +0 |

> Note 2026-10-10 (spec 2610.0011): the `compat BackCompat` reading of S16 is
> the reading before standards mode. A card file that starts with a doctype
> now reads `compat CSS1Compat`; the numbers of S16 do not change. This is from
> the spec's standalone WebKit probe, not from a live run.

S19's captures in the hold were not timed: the thumb in each is what says it
was inside. S37's, by the same two commands, were. Not run: the hairline's
width after a move to a display of another density — there is one display
here.

Six things the runs found:

- **S31 as first specified could not pass.** It waited for `scroll` to read
  `null` during the probe's reload at zoom 1, where the nil lasts a frame: the
  outgoing document reports once more, because its frame is resized while the
  incoming document's mode is unknown. Where the frame keeps its size — a
  reveal card, or zoom 3 — the nil stands until the new document reports, and
  that is what the scenario checks now.
- **The thumb was first laid against the body's whole container.** Below zoom
  1 on a 1× display the border is held at a whole device pixel, so the
  container overhangs the content area, and the thumb's inset went with it:
  against the border at zoom 0.5, one of its two columns cut off at 0.25 (it
  was 6 wide then), outside the clip at 0.2 with `shown` true. It is laid against the part that
  shows now (`CardBox.Screen.shownBody`).
- **At zoom 0.1 the card does not take the wheel.** A gesture over the middle
  of the selected white page, 39 × 31 on screen, pans the board (`cy` 53.7 →
  −246.3) and `shown` stays false.
- **The thumb was first a translucent fill**, and read as grey on a white page
  and as dark with a light edge on a dark one: the same box, the page's tone.
  It is opaque now, and S37 reads its colours.
- **The thumb was first 6 wide.** Seen in the app, the user asked for a thicker
  one: 10.
- **A terminal needs no push at its card's mount.** With none, both restored
  terminals carry metrics at launch, one that has printed nothing since
  included, and so does the terminal a fresh channel starts with: (0, 12, 12)
  in its first snapshot.
