# New terminal card mounts at the board's settled raster scale — manual QA (spec 2609.0005, #87)

S1–S4 of `.blueprint/specs/2609.0005_new_terminal_card_zoom_scale.md`. These are
[Q] scenarios by necessity, not by preference: the contract is *what `FitAddon`
computes for a real xterm inside a real `rs ×` host*, and `desktop/` has no jsdom
or xterm harness (see the repo testing convention). There was one automated
scenario, **S5** — a drift tripwire on the padding constant, which **passed on a
completely unfixed build and was not evidence of anything below**. #117 (spec
`.blueprint/specs/2609.0007_term_host_padding.md`) removed the duplicated constant
it pinned, and with it the tripwire: the padding contract is now QA-only. This
sheet is the only durable artefact of the fix.

Run against `make run` with a fresh dev daemon (`make kill-daemon` first).

**CAUTION: do NOT `pkill tarmacd`.** That kills the user's installed Tarmac and
every terminal its daemon owns. It is also unnecessary: `make run` pins
`TARMAC_SOCKET=$(ROOT)/.dev/tarmacd.sock` and `TARMAC_STATE=$(ROOT)/.dev/state.json`
(`Makefile`), so the dev app and an installed app use different sockets and
different state and coexist fine. `make kill-daemon` is the correct tool — it
resolves the pid with `lsof -t` on *this worktree's* dev socket and cannot touch
the installed daemon. (The older "a persistent installed daemon hijacks the dev
app" warning predates those per-worktree pins.)

**If an installed Tarmac is running there will be two windows on screen**, both
named `tarmac-app` and sharing bundle id `com.tarmac.desktop`. Address the dev
window by pid, and confirm which is which before any keystroke.

## Setup

### The reference card, and why its spawn order is load-bearing

Every scenario is decided by comparison against a second terminal card **of the
same frame size** that was already open *before* the board settled at the scale
under test. Same frame size is a precondition, not a detail: `cols × rows` is
derived from the card's box, so two differently sized cards legitimately disagree
and the comparison carries no information. Every ⌘T terminal is spawned at
`Place.termFrame = { w: 470, h: 330 }` (`desktop/src/kit/placement.ts`), so two
un-resized cards satisfy it by default — **do not resize either card.**

**Spawn the reference at 100 %, zoom afterwards.** A reference spawned *after* the
board reached `rs > 1` is born through the same defective path as the card under
test, so a broken build makes both cards equally wrong and every scenario below
passes falsely. The order is always:

1. ⌘T at 100 % → this is the **reference** card. Let it settle; read `stty size`.
2. Zoom to the level the scenario names with the bottom-left `+` control.
3. Wait at least half a second (`RASTER_SCALE_SETTLE_MS` is 150 ms,
   `desktop/src/kit/rasterScale.ts`) so the settle has reached the reference card.
4. Re-read `stty size` in the **reference** card — it may have moved by one column
   across the settle (see S4's scrollbar note). That post-settle reading, not the
   100 % one, is what the new card is compared against.
5. ⌘T again → this is the **card under test**. Make **no** pan or zoom gesture
   after this point unless the scenario explicitly says to.

### The three tells

Each detects something the other two cannot. Read all three every time.

1. **`cols × rows`** — run `stty size` inside *each* shell (prints `rows cols`;
   `tput cols` / `tput lines` also work). This is the PTY-visible half and the
   expensive one: it is what the daemon was told. Detects the `fontSize` half.
2. **Glyph size** — by eye, the two cards side by side at the same board zoom.
   The same `fontSize` half seen from the user's side. Under the bug the new
   card's glyphs are `1/rs` of the reference's — at `rs = 2` that is half-size and
   unmissable.
3. **Gutter width** — the inset from the card body's left edge to the first glyph
   column. **This is the ONLY tell for the padding half.** `stty size` is provably
   blind to it (the global `* { box-sizing: border-box }` in
   `desktop/src/theme/tokens.css` means `FitAddon` already measures a host width
   that includes the padding, so a font-only fix yields a byte-identical grid),
   and glyph size is set by `fontSize` alone. A correct gutter is
   `10 px × board zoom` on screen regardless of `rs`; a missing padding fix makes
   it `1/rs` of that. Compare the two cards' gutters **directly, side by side** —
   at `rs = 2` the broken card's left gutter is half the reference's
   (≈ 9 px against ≈ 17 px at 173 % board zoom).

### Reaching the zoom levels

The bottom-left zoom control (`− / <percent> / + / ⊡ fit`) steps by 1.2×
(`ZOOM_STEP`, `desktop/src/App.tsx`). From 100 %, each press of `+` gives:

| presses of `+` | readout | board zoom | `deriveRasterScale` |
|---|---|---|---|
| 0 | 100 % | 1.0 | 1.0 |
| 1 | 120 % | 1.2 | **1.5** |
| 2 | 144 % | 1.44 | **1.5** |
| 3 | 173 % | 1.728 | **2.0** |
| 4 | 207 % | 2.0736 | 2.5 |
| 5 | 249 % | 2.48832 | 2.5 |
| 6 | 299 % | 2.98598 | **3.0** |

So **`rs = 2` is three presses (readout 173 %)** and **`rs = 3` is six presses
(readout 299 %)**. There is no zoom-reset shortcut; pressing `−` the same number
of times returns the viewport to exactly 1.0, and `⊡ fit` does **not** — it frames
the cards at whatever zoom that takes. Note `deriveRasterScale(1.5)` is `1.5`, not
`2`, so "zoom to 150 %" would be the wrong instruction; use the readouts above.

**Confirm the readout says `100%` before you spawn the reference card.** The
viewport is restored from persisted state, so a board reopened mid-zoom starts
somewhere off the ladder and none of the readouts above will appear. If it does,
start from fresh dev state: `make kill-daemon`, delete the worktree's
`.dev/state.json`, relaunch `make run`.

Record the readout you actually used in **Run conditions** at the end of this
sheet, and every `cols` you read in the observation table.

## S1 — spawn onto a board already settled at `rasterScale = 2`

**The scenario the fix exists for.** It is the only one that exercises the new
code path at all: at `rs = 1` the change is an exact no-op by construction.

- [ ] ⌘T at 100 % → reference card. Read and record its `stty size`.
- [ ] Press `+` three times (readout **173 %**). Wait half a second.
- [ ] Re-read the reference card's `stty size` and record it — this post-settle
      value is the comparand.
- [ ] ⌘T → the card under test. **Make no pan or zoom gesture afterwards.** This
      is the whole point: the bug's only repair path is a bucket-crossing settle,
      so any gesture here can let a broken build pass.
- [ ] **Tell 1** — `stty size` in the new terminal equals the reference card's
      post-settle `rows cols` exactly. Under the bug it is ≈ 2× both — `stty size`
      would print roughly `33 96` where a correct card prints `16 48`
      (that is `rows cols`; the spec quotes the same pair as `48 × 16` cols×rows).
- [ ] **Tell 2** — the new card's glyphs are the same on-screen size as the
      reference card's, side by side. Under the bug they are half-size.
- [ ] **Tell 3 (the padding half — do not skip)** — the gutter between the card
      body's left edge and the first glyph column is the same width on both cards.
      Under a font-only fix this is the *only* item that goes red: `cols × rows`
      and glyph size are already correct there.
- [ ] Pass iff all three hold.

**Not run as a measured scenario — see *Run 2* and *Owner sign-off* at the end of this sheet.** (2026-09-06.) The first step is ⌘T, and no keystroke could be
delivered to the app on this machine (see *Blocker* in Run conditions). No card
under test ever existed, so none of the three tells was read. Every box above is
unticked because nothing above was attempted, not because anything failed.

## S2 — spawn at rest (`rasterScale = 1`) — no-regression pin

Be honest about what this buys: at `rs = 1` the fix is an exact no-op
(`termFontSize * 1`, and `termHostPadding(1)` *is* the CSS literal), so this can
only catch a botched implementation — a wrong variable, a `NaN`, an `rs` read
before it is assigned. It is not a behavioural contract and not evidence the fix
works.

- [ ] Start with the board at 100 % (readout `100%`, board zoom ≤ 1).
- [ ] ⌘T → reference card. Read and record its `stty size`.
- [ ] ⌘T again → the card under test. No gesture in between.
- [ ] Glyphs are the same on-screen size on both cards.
- [ ] `stty size` reports the same `rows cols` on both.
- [ ] Gutters are the same width on both.
- [ ] Pass iff all three hold. Anything red here is a botched implementation, not
      a scale bug.

**Not run as a measured scenario — see *Run 2* and *Owner sign-off* at the end of this sheet.** (2026-09-06.) Same blocker: both cards S2 compares are ⌘T spawns, and
⌘T could not be delivered. The board's 100 % readout *was* confirmed on screen,
but no card was spawned.

## S3 — correct without ever needing a settle (bucket 1.5, within-bucket move)

Stated at bucket **1.5** on purpose: 120 % and 144 % are two consecutive presses
of the `+` control and both derive `rs = 1.5`, so this is runnable with the
control alone. At bucket 2.0 no two reachable levels share a bucket and this would
need a pinch gesture.

Both halves are required, and **the first is the load-bearing one**: the
no-movement half alone is satisfied by the *broken* build, where a same-bucket
settle never fires (`BoardEngine` invokes the callback only on an actual change)
so a wrong card simply stays wrong. What this pins is that the card is correct
**without** a settle ever repairing it.

- [ ] ⌘T at 100 % → reference card. Record its `stty size`.
- [ ] Press `+` once (readout **120 %**). Wait half a second. Re-read and record
      the reference card's `stty size`.
- [ ] ⌘T → the card under test. No gesture yet.
- [ ] **Half 1 — S1's three tells at this scale**: same `stty size` as the
      reference, same glyph size, same gutter width. Record all three.
- [ ] Press `+` once more (readout **144 %** — same bucket, `rs` stays 1.5). Wait
      half a second.
- [ ] **Half 2 — nothing moved.** `stty size` in the new terminal is *unchanged*
      from the reading you just took, and the two cards still match each other on
      glyph size and gutter width.
      **Note on "same on-screen size":** 120 % → 144 % grows every card by 1.2×,
      so glyphs and gutters legitimately get bigger in absolute pixels. The
      criterion is that the two cards still match **each other**, and that
      `cols × rows` did not move — not that anything is the same absolute size as
      before the gesture.
- [ ] Pass iff both halves hold.

**Not run as a measured scenario — see *Run 2* and *Owner sign-off* at the end of this sheet.** (2026-09-06.) Same blocker. The 120 % rung of the ladder was reached
with the `+` control and confirmed on screen, but with no ⌘T there was no card
under test to compare.

## S4 — an existing settle still lands on a card the mount already seeded

- [ ] Reach an S1-passing state at `rs = 2` (reference card, three presses,
      readout 173 %, card under test spawned after the settle). Record both cards'
      `stty size`.
- [ ] Press `+` three more times (readout **299 %**, `rs = 3`). Wait half a second.
- [ ] `rows` in the new terminal is **unchanged**.
- [ ] `cols` in the new terminal is unchanged **or differs by at most one column**
      — see the pre-authorisation below.
- [ ] Glyphs and gutters still match the reference card's, side by side (again:
      both grow in absolute px with the board zoom; the criterion is that the two
      cards agree).
- [ ] Pass iff all four hold. A compounding double-application of the scale would
      show as a *gross* jump in the grid, never as one column.

**Not run as a measured scenario — see *Run 2* and *Owner sign-off* at the end of this sheet.** (2026-09-06.) S4 begins from "reach an S1-passing state", and S1 was
never run (same blocker).

**±1 column across a settle is expected, not a regression.** `FitAddon` subtracts
a fixed `DEFAULT_SCROLL_BAR_WIDTH = 14` px that does **not** scale with `rs`, so

    cols(rs) = floor((rs·W − 14) / (rs·c))

drifts upward with `rs`. The spec's measurement on the default 470 × 330 frame is
`47` at `rs = 1` against `48` at `rs = 2` — *expected values quoted from
`.blueprint/specs/2609.0005_new_terminal_card_zoom_scale.md`, **not** observed on
this run.* Rows carry no such term and are exactly invariant. This is pre-existing
and out of scope for #87; it is also why the reference card's own `stty size` can
legitimately move by one column when the board first settles above 1×.

## Observation table

Fill one row per `(scenario, rs)` actually exercised. **Do not invent a number you
have not read.** `rows cols` is `stty size`'s own order.

| scenario | readout | board zoom | rs | reference `rows cols` | new card `rows cols` | glyphs match? | gutters match? |
|---|---|---|---|---|---|---|---|
| S1 |  |  | 2.0 |  |  |  |  |
| S2 |  |  | 1.0 |  |  |  |  |
| S3 (before) |  |  | 1.5 |  |  |  |  |
| S3 (after) |  |  | 1.5 |  |  |  |  |
| S4 (before) |  |  | 2.0 |  |  |  |  |
| S4 (after) |  |  | 3.0 |  |  |  |  |

**No row has been filled.** Neither run executed a scenario, so there is no
reference/new-card pair to record. The repo owner's sign-off (below) is a visual
acceptance of the built app, not a set of per-tell readings, and is deliberately
not transcribed into this table — a number here must be a number someone read. The two readings that run *did* produce
are logged under *Incidental observations* below; they are the pre-existing boot
card's own numbers, not a scenario result, and they decide nothing about #87.

## Run conditions

*Run attempted 2026-09-06; blocked before any scenario. Details below.*

- **Commit under test:** `9175b49` on `fix/87-new-card-zoom-scale`, **with the
  fix uncommitted in the working tree** — `desktop/src/cards/TerminalCard.tsx`,
  `desktop/src/kit/termHostPadding.ts` and
  `desktop/src/kit/termHostPadding.test.ts` modified; the spec and this sheet
  untracked. So `9175b49` names the base, not the code that ran.
- **Date:** 2026-09-06, ~20:03–21:00 CST.
- **Display:** BenQ EW2770QZ, 2560 × 1440, **1×** ("UI Looks like: 2560 × 1440"),
  the Mac's main display. The app window was moved there and sized to
  2540 × 1358 at (0, 38). The built-in Retina panel was left to the user's own
  installed Tarmac and was never used for measurement.
- **Launch:** `make run` from the worktree, so the Makefile's own pins applied —
  `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock`,
  `TARMAC_STATE=<worktree>/.dev/state.json`,
  `TARMAC_DAEMON=<worktree>/core/target/debug/tarmacd`. `.dev/` did not exist
  beforehand, so the board started from fresh state: one boot terminal card,
  470 × 330, viewport zoom 1.0.
- **Installed `tarmacd` killed before the run?** **Yes, and that was a mistake** —
  see *Incident* below. The dev daemon does not need it killed: `make run` pins
  its own socket and state, so the two instances coexist.
- **Zoom readouts actually used:** `100%` (confirmed on screen before anything
  else) and `120%`, reached with one registered press of the bottom-left `+`.
  `173%` and `299%` were never reached — there was no card to spawn onto them.

### Blocker — keystrokes could not be delivered to the app

Every scenario on this sheet starts with ⌘T, and **⌘T could never be delivered**.
The automation layer driving the GUI could not see the Tarmac window at all: its
screenshots showed only the desktop wallpaper at coordinates where the window
demonstrably was. Mouse events still landed (window activation, board scroll-pan,
and the `+` zoom button all took effect, the last only intermittently — two
clicks yielded one zoom step), but keyboard events were refused outright with
`no app is frontmost (focus anomaly)` when batched, and the four standalone ⌘T
calls that each *reported* success produced no card at all — the false success is
itself part of the defect. ⌘T is the **only** way to create a terminal card:
`spawnNewTerminal` has exactly one call site, the ⌘T branch of the keydown
handler at `desktop/src/App.tsx:1389`, and there is no button, menu item, or
gesture equivalent. With no second card, none of S1–S4 is decidable.

For the same reason `stty size` was never typed into a card. (The PTY grid can be
read from outside with `stty -f /dev/ttysNNN size` on the daemon's child shell,
which is the same `TIOCGWINSZ` fact; that is how the two incidental readings
below were taken. It was not used to fill any scenario, because there was no
card under test to read.)

**To unblock:** press ⌘T by hand at each point the sheet calls for it, or re-run
where the automation layer can see and type into the Tarmac window.

### Incident — the user's installed Tarmac was killed

Following an instruction that was corrected too late, this run began by
terminating the user's running installed Tarmac (`kill` on the app, then `kill -9`
on its daemon) at ~20:02. The user relaunched it within about a minute; its board
state (`~/Library/Application Support/tarmac/state.json`) was untouched and
restored, but any terminals it owned were killed with the daemon. (The relaunch
happened between ~20:03 and 20:04; the first direct evidence of it is the
`▞ tarmac` window seen in a 20:04 window read.) Afterwards, a
window-geometry call made by process *name* (`tarmac-app`, which both builds
share) moved and resized **the user's** window instead of the dev one; it was
restored to its exact original frame (2763, 69) 1561 × 1057 at ~20:07. From then
on every window call addressed a specific pid and every click was confined to the
dev window on the BenQ display. One `escape` keypress at ~20:04 went to whichever
Tarmac was frontmost and may have reached the user's session; the session
appeared unaffected. The user's board carried 4 terminal tiles before, during,
and after this run.

### Deviations and noise

- **Screenshots of the app were taken with `screencapture -R`,** bounded to the
  dev window's rectangle, because the automation layer's own screenshot could not
  see the window. Every image used here shows only the dev app.
- The dev window was moved and resized through System Events (addressed by pid
  28536) to fill the BenQ display; the board itself was not resized and no card
  was resized.
- **Finder was granted to the automation layer at ~20:52**, purely to lift a
  guard that was refusing clicks inside the Tarmac window as "desktop shell"
  clicks (the window being invisible to that layer). Clicks were refused before
  that grant and landed after it.
- Two Tarmac instances ran simultaneously for most of the session (the user's
  installed build on the built-in display, the dev build on the BenQ). They share
  the bundle id `com.tarmac.desktop`, which is the suspected cause of the
  automation layer's focus/visibility failure, though that was not proven.

### Incidental observations (not scenario results)

Taken on the **pre-existing boot card** — a 470 × 330 terminal that was already
open at 100 % — with `stty -f /dev/ttys002 size`, which prints `rows cols`:

| board readout | rs | boot card `rows cols` |
|---|---|---|
| 100 % | 1.0 | `15 50` |
| 120 % | 1.5 | `14 49` |

The board was also scroll-panned between the two readings. Panning does not
change `rasterScale`, so the 1.0 → 1.5 attribution holds, but it is recorded here
rather than left out.

These decide nothing about #87: this card was spawned at rest and repaired (if it
needed repairing) by the ordinary settle path, which is not the path the fix
touches. They are recorded only because they were actually read. Note in passing
that `rows` moved by one across the settle, where §S4 of this sheet expects rows
to be exactly invariant; that was not investigated and is not a #87 finding.

---

## Run 2 — 2026-09-06, ~21:18 CST

A second launch, driven from the shell rather than through the GUI automation
layer that blocked Run 1. No scenario was executed here either; what it
established is recorded because it is what was actually observed.

- **Commit under test:** same as Run 1 — base `9175b49` on
  `fix/87-new-card-zoom-scale`, with the fix **uncommitted** in the working tree.
- **Launch:** `make kill-daemon`, then `rm -f .dev/state.json`, then `make run`
  from the worktree. Fresh dev state by construction.
- **Processes:** dev app pid `16382`, dev daemon pid `16768` (bound to
  `<worktree>/.dev/tarmacd.sock`). The user's installed Tarmac (`23356`) and its
  daemon (`23368`) **were not touched this run** — see the corrected CAUTION at
  the top of this sheet.
- **Board:** window titled `board-0`, one boot terminal card, zoom readout
  **`100%` confirmed on screen**.
- **`screencapture -x` sees the window.** The full-screen capture showed the dev
  window, its zoom readout and its card contents clearly. This is worth recording
  as a working substitute for the automation layer's own screenshot, which showed
  only wallpaper in Run 1 — a future runner should reach for `screencapture`
  rather than assume the window is uncapturable.
- **Keystrokes were not attempted.** An AppleScript activation addressed at the
  dev app's pid brought the **installed** app frontmost instead, confirming that
  the two same-named processes cannot be reliably targeted this way. No key event
  was sent, deliberately: sending ⌘T to the wrong window would have created a card
  on the user's real board.
- **Incidental reading**, same method as Run 1
  (`stty -f /dev/ttys002 size`, prints `rows cols`), on the pre-existing boot
  card at readout `100%`: **`15 48`**.

  Run 1 read `15 50` for the same card at the same readout. The difference is
  explained by window size, not by the fix: Run 1 resized the app window to
  2540 × 1358 on the BenQ, Run 2 left it at its default size. Neither reading is
  a scenario result — the boot card is spawned at rest and is not on the mount
  path the fix touches.

## Owner sign-off

**2026-09-06 — the repo owner reports the implementation as visually correct
("目測實作 ok") after exercising the built app themselves.**

Recorded as exactly what it is, and no more:

- It is an **acceptance by the person who owns the code and the bug**, on a build
  containing the fix. That is real evidence and is why this sheet is not simply
  "unverified".
- It is **not** a per-tell measurement. The procedure followed, the zoom readouts
  used, and the values of the three tells were not reported, so none of the
  checkboxes under S1–S4 is ticked and no row of the observation table is filled.
  Ticking them from a general "looks right" would assert readings nobody recorded.
- In particular, **tell 3 (gutter width) has no recorded observation**. It is the
  only tell that can detect the padding half of the fix — `stty size` is provably
  blind to it and glyph size is set by `fontSize` alone — so the padding half of
  the change remains the least-evidenced part of this work.

**Standing gap.** The spec's Definition of Done asks that S1–S4 "have been run
against `make run` and their outcome recorded in that file", and that the sheet
"records the observed `cols` at each `rs` exercised". On the evidence above, the
first is partially met (the app was exercised and accepted, but not scenario by
scenario) and the second is not met. Closing it needs one guided pass: with the
dev app running, ⌘T a reference card at 100 %, `+` three times to 173 %, re-read
the reference, ⌘T the card under test, then read both cards with
`stty -f /dev/ttysNNN size` and compare the two gutters side by side. That is the
whole of S1, and S1 is the only scenario that exercises the new code path.
