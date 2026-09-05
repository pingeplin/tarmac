# Doc card refresh manual QA checklist (spec 2609.0001, issue #89)

The [Q]-tagged scenarios S13–S20 the unit suites cannot cover: the React/Tauri
shell has no unit tests by design (only pure `kit/` logic and Rust are tested).
Run against `make run` with a fresh dev daemon (`make kill-daemon` first).

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`), since
a persistent installed daemon hijacks the dev app. This matters more here than for
any earlier QA sheet: every item below observes daemon-side behavior that does not
exist in an installed build, so a hijacked session fails S15–S20 for the wrong
reason and looks like a broken feature.

## Status: VERIFIED — 8/8 PASS (2026-09-05, commit `eb47e28`)

**S13–S20 all ran and all passed**, against the debug build of `eb47e28` — the
PR's feature commit, before it was squashed into `15812af` — driven through the
real UI in `../tarmac-worktrees/89-doc-card-refresh` (since removed; that is the
worktree every `<worktree>` path below names). Every checked box was observed on
screen except where an Observation says the reading was uncaptured; screenshots
are named in each Observation line and live outside the repo in
`../tarmac-worktrees/qa89-scratch/`.

How the session was set up, since three details deviate from the sheet's literal
instructions and a later reader needs to know:

- **Daemon isolation was by socket, not by `pkill`.** The installed `tarmacd`
  belongs to a Tarmac the operator had open, so it was left running; the dev app
  and every `tarmac open` in this run used `TARMAC_SOCKET=<worktree>/.dev/tarmacd.sock`,
  and the daemon serving them was this worktree's `core/target/debug/tarmacd`
  (verified by `lsof` on that socket). Nothing in the run reached the installed daemon.
- **The board switches in the stale-card recipe were driven over the daemon socket**
  (`board_create` / `board_switch`) rather than with `⌘K`/`⌘N`/`⌘1`: synthetic
  keystrokes never reached the dev app's webview in this environment (an
  automation/input-source artifact — mouse input worked throughout), so the
  keyboard path was unavailable. This is the same mechanism the recipe relies on:
  the daemon's active board really moved to board-1, the app really followed
  (its window title read `board-1`), the edit really was dropped by `watch_loop`
  (`state.json` kept the pre-edit `last_changed_ms` — checked every time before
  clicking), and the app really came back to board-0 still showing the old bytes.
  **One honest difference:** `board_create`/`board_switch` are app-role messages,
  so each call replaced the app's daemon connection (`install_app` cancels the
  previous slot — hence a "tarmacd connection lost" toast); the app reconnected
  and re-derived the active board from the fresh `board_list`. The stale card
  therefore survived `applyRestore`'s already-visited early return on a
  *reconnect* restore rather than on a *switch* restore. Same guard, same
  outcome, slightly different entry point — worth knowing if you re-read
  `conn.rs` against this record.
- **The app was started from a hand-built wrapper bundle, not `make run`.**
  `qa89-scratch/TarmacDev.app` (bundle id `com.tarmac.qa89dev`) wraps a copy of
  the worktree's own `desktop/src-tauri/target/debug/tarmac-app` and carries
  `TARMAC_SOCKET` / `TARMAC_STATE` / `TARMAC_DAEMON` / `PATH` into the worktree
  through `LSEnvironment` — the same values `make run` prefixes. The raw
  `tauri dev` binary could not be used: it was invisible to the computer-use
  screenshot filter and shared the installed app's bundle id, so it could
  neither be captured nor told apart from the Tarmac the operator had open (see
  issue #102). The wrapped copy was checked to carry the same LC_UUID as the
  worktree binary, and the daemon log reads
  `tarmacd (dev) listening on <worktree>/.dev/tarmacd.sock` continuously across
  the run. This changes only how the app was launched — not which binary, which
  daemon or which socket was observed.

**The app was relaunched mid-run.** The wrapper was rebuilt at ~08:25 and the app
restarted at 08:26 (`app connected (generation 3)` in the daemon log; the
generation numbers climbing from 08:35 on are the `board_create`/`board_switch`
reconnects described above, not further launches). S13/S14/S16/S18/S20 ran on the
first launch (08:09–08:14), S15/S17/S19 on the third (08:36–08:44). The relaunch
remounted every card, which is why S17's stale baseline reads console badge 5 —
one load's worth of lines — where S16 and S20 had left the same card at 10, and
why its `aliveSec` reads 620: 620 ticks before the 08:36:35 capture puts the load
at ≈08:26, the relaunch, not the card's original open.

**Daemon state was read live, not snapshotted.** The `last_changed_ms` values
quoted in S15/S18/S19/S20 were read from `<worktree>/.dev/state.json` at the
moment of each observation; that file went away with the worktree and is not part
of the evidence set. What still corroborates the mechanism is the source files
themselves: `qa89-scratch/docs/probe.md`'s mtime is `1788569051444` to the
millisecond — exactly the value S19 quotes. S15's, S18's and S20's values sat on
files that later edits in the same run overwrote, so they can no longer be
re-derived.

Automated coverage that also exists, for context:
`core/crates/tarmacd/tests/doc_refresh_integration.rs` (S3–S10, S21, S22 — the whole
daemon contract, including the watcher-missed-it case) and the `cardSrcUrl` purity
guard S11 in `desktop/src/kit/docKind.test.ts`. What this sheet adds is the UI
shell: the control's presence, its drag behavior, and the on-screen result of a
refresh.

## The stale-card recipe (used by S15, S17, S19)

On macOS + FSEvents there is no user-reachable way to make the *active* board's
watcher miss an edit, so stage it the way the daemon actually produces it:

1. Open the doc as a card on board-0.
2. Switch to board-1 (the doc must **not** also be open there).
3. Edit the file on disk. `watch_loop` matches events against the active board's
   registry when the debounced batch is processed, so the edit is dropped.
4. Switch back to board-0.

The switch heals nothing — `applyRestore` early-returns for an already-visited
board — so the card still shows the old content, the old recency label and the old
`?v=`. **Confirm that stale baseline before clicking refresh**; a scenario that
refreshes an already-current card proves nothing.

## S13 — the control is present on both card kinds — PASS

- [x] A markdown doc card shows `↻` in its header without hovering.
- [x] A live HTML card shows it too.
- [x] Order is recency label → `↻` → console badge (when present) → `✕`.
- Observation: `s13.png` / `s13_headers.png` — `probe.md` reads
  `¶ probe.md … ✚ now ↻ ✕` and `qa-magnify.html` reads
  `</> qa-magnify.html … ✚ now ↻ ⌥5 ✕`. `screencapture -x` omits the cursor, so
  the pointer's position is not in the frame; what evidences "without hovering" is
  that neither `↻` carries the hover chip `s19_hdr.png` and `s20_second_card.png`
  show behind a hovered control. Both cards were freshly opened, so the slot
  before `↻` held the fresh marker rather than a recency label; `s19_hdr.png`
  shows the same slot occupied by the real recency label
  (`¶ probe.md … ✎ 19s ↻ ✕`), so the full order is evidenced across the two.

## S14 — the control does not drag the card — PASS

- [x] Press on `↻` and drag: the card does **not** move.
- Observation: `s14.png` — pressed on `probe.md`'s `↻` and dragged ~85×60 screen
  px; the card did not move and its persisted tile stayed at `x=636, y=80`.
  `s13.png` and `s14.png` are pixel-identical apart from two regions that are not
  the card: the HTML card's ticking `aliveSec` counter and the menu-bar clock.
  **Uncaptured:** the control run — the identical drag started from the header
  *background* moved the same card to `x=740, y=184`, so the drag mechanism was
  live and only `↻` suppressed it — was watched live. No screenshot was taken and
  its `state.json` read was not preserved, so it is an operator note rather than
  evidence, and the "not vacuous" claim rests on it. Card dragged back afterwards.

## S15 — markdown refresh, scroll preserved (the #89 user story) — PASS

- [x] With a markdown card made stale by the recipe above and scrolled partway
      down, click `↻`: the **new** content renders (verifiably the edited bytes,
      not the pre-edit ones).
- [x] The scroll position is preserved — no jump to the top.
- Observation: `s15_before.png` → `s15.png`. Stale baseline confirmed first: the
  card showed `BASELINE-02` / `BASELINE-03` while the file on disk already read
  `ROUND2-SECTION-02` / `ROUND2-SECTION-03`, and the daemon registry still held
  the pre-edit `last_changed_ms` (1788568813478 vs the file's 1788568868). The
  card was scrolled so its top visible line was section 01's body. After the
  click the two edited paragraphs render as `ROUND2-SECTION-02/03`, section 01
  (untouched) still reads `BASELINE-01`, the same line is still the top visible
  line — no jump to the top — and the registry moved to 1788568868835.

## S16 — unchanged HTML card is not reloaded — PASS

Precondition: the card's `lastChangedMs` is already populated (it has taken at
least one `file_event` — a prior edit or a prior refresh). S20 covers the
un-populated card, which behaves differently on purpose.

- [x] With a magnify HTML card at board zoom ≠ 1 whose file has **not** changed,
      click `↻`: the document does **not** reload (page-local state such as a
      running counter survives).
- [x] The card's rendered size does not change.
- Observation: `s20_second_card.png` (before) → `s16.png` (after). Board zoom
  145%; the probe copy carries a per-load random `loadId` and a `setInterval`
  seconds-since-load counter. Before — the same reading S20's second click ends
  on, which is why that one capture serves both: `loadId=9948`, `aliveSec=53`,
  console badge 10 (its `lastChangedMs` had been populated by the S20 first
  click). After the click: `loadId=9948` unchanged, `aliveSec=85` (kept counting
  straight through), badge still 10, and the probe's measured box occupies exactly
  the same rectangle as before — (2406,892)–(3404,1352), 998×460 device px. No
  reload, no resize.

## S17 — changed HTML card reloads and comes back at board zoom — PASS

Use `desktop/qa/magnify-probe.html` — it declares `tarmac-zoom`, so `HtmlCard`
logs a host-side `zoom-mode declared=…` console line per load. Copy it outside the
repo before editing so the QA run does not dirty the worktree.

- [x] With that card at board zoom ≠ 1 made stale by the recipe above, click `↻`:
      it reloads (page-local state resets).
- [x] The console badge count goes **up** — the card is never unmounted, so the
      reload appends to the existing buffer rather than starting a fresh one.
      (It grows by **5**, not 1: a `magnify-probe.html` load produces five console
      entries — `HtmlCard`'s own host-side `zoom-mode declared=…` line, the
      probe's `report()` on load, the probe's "received zoom" line, the `report()`
      that message triggers, and one further `report()` driven by the `resize`
      the root zoom causes. Five is this document's number, not a constant; the
      spec's "+1" assumed a one-line document. What matters, and what was
      observed, is that the buffer *continued* from 5 to 10 instead of restarting
      at the per-load count.)
- [x] The document comes back at the current board zoom, **not** at 1/K (the #99
      shape).
- Observation: `s17_before.png` → `s17.png`. Board zoom 145%. Stale baseline
  confirmed (`s17_before_card.png`): banner still `QA89 BANNER: BASELINE`,
  `loadId=6833`, `aliveSec=620`, badge 5 — see the relaunch note above for why the
  badge is 5 and not 10 — and no recency label, while the file on disk already
  read `EDIT-1` and the registry still held the pre-edit mtime. After the click:
  banner `QA89 BANNER: EDIT-1`, `loadId=2197`, `aliveSec=8` (page state reset), badge
  5 → 10. Zoom check: the probe box keeps the identical left/right edges and width
  (x 2406→3404, 998 device px) before and after; only its height shrank
  (460→362 px) because the new banner is one text line shorter. 1/K would have
  been ≈333 px wide, so this is board zoom, not the #99 shape.

## S18 — an unchanged, stale-dated refresh is invisible — PASS

- [x] Click `↻` on an unchanged doc older than the 30 s recency window (a markdown
      card, or an HTML card whose `lastChangedMs` is already populated): nothing
      visible happens — no spinner, no synthetic "just refreshed" label.
- [x] On a markdown card scrolled partway down, neither the rendered content nor
      the scroll position moves.
- Observation: `s18_before.png` → `s18.png` — `probe.md`, unmodified, mtime ~30
  minutes old (`1788565209578` = 07:40:09, captured at 08:10), card scrolled to
  sections 02–04. After the click the two captures are pixel-identical apart from
  the `↻`'s own hover box: same paragraphs, same scroll offset, no label appears,
  no spinner. Not vacuous: the click really reached the daemon — the doc's
  `last_changed_ms` went from `null` to `1788565209578` (the file's true mtime) in
  `state.json` at that moment; it simply matched what the app already had, so
  nothing rendered.

## S19 — the recency label shows the edit's age, not the click's — PASS

- [x] With a markdown card made stale by the recipe above and the edit inside the
      30 s window, click `↻`: the header shows `✎ Ns` stamped from the file's real
      mtime.
- [x] N is the age of the **edit**, not of the click — the captured reading is
      larger than any click-stamped label could have been at that moment.
- Observation: `s19_hdr.png` (cropped from `s19.png`), captured at 08:44:30, reads
  **`✎ 19s`** against `probe.md`'s mtime of 08:44:11.444 — epoch `1788569051444`,
  the value the registry moved to and still the file's mtime today. The edit was
  written while board-1 was active and dropped by the watcher (the registry still
  held the pre-edit `1788568868835`). The click landed after 08:44:15 — the daemon
  log's board-switch reconnect pairs at 08:44:08/09 and 08:44:14/15 bracket the
  edit — so a label stamped from the click could have read no more than 15 s at
  that capture. 19 s is the edit's age, counted from its real mtime.
  **Uncaptured:** the pre-click header (carrying no recency label for that edit)
  and the first post-click reading (`✎ 9s`) were watched live, not screenshotted.

## S20 — first refresh of a never-changed HTML card reloads once — PASS

This is the accepted one-time-reload trade-off (spec Open Question 1) made
observable. A freshly opened card has no `lastChangedMs`, so its iframe sits at
`?v=0` until the first `file_event` populates it.

- [x] With a magnify HTML card freshly opened and never changed since, at board
      zoom ≠ 1, click `↻` **once**: the document reloads even though the file did
      not change (page-local state resets, console badge count goes up — +5 here,
      see the S17 note on this probe's per-load line count).
- [x] It comes back at the current board zoom, **not** at 1/K. If it lands at 1/K
      that is the #99 shape and a blocker, not an accepted trade-off.
- [x] Click `↻` a **second** time with still no edit: nothing reloads (page-local
      state survives).
- Observation: `pan1.png` (before — `loadId=2432`, `aliveSec=211`, badge 5),
  `s20_first.png` (first click) and `s20.png` (second click). Card opened minutes
  earlier and never edited — `last_changed_ms` was `null` in
  `state.json`, i.e. the iframe sat at `?v=0`; board zoom 145%. First click:
  `loadId` 2432 → 9948, `aliveSec` reset to 7, badge 5 → 10, and
  `last_changed_ms` became `1788565218170` — one reload, exactly as the trade-off
  predicts. **Zoom is correct**: the probe box occupies the identical rectangle
  before and after the reload, (2406,892)–(3404,1352) = 998×460 device px; a 1/K
  landing would have been ≈333 px wide. Second click ~12 s later with no edit:
  `loadId` still 9948, `aliveSec` 53 (counted straight through), badge still 10 —
  nothing reloaded. Merge gate satisfied.

## Incidental observations (out of scope for #89, recorded so they are not lost)

- **A board switch resets a markdown card's scroll position.** Seen twice while
  staging the recipe: park a scrolled `probe.md` on board-0, switch to board-1 and
  back, and the card is at the top again. It happens on the switch, before any
  refresh — the S15 scroll check above was made against a card re-scrolled *after*
  the switch, so it is unaffected. Pre-existing behaviour, unrelated to `↻`.
- **Nothing about the refresh control itself misbehaved.** The only friction in
  the run was the harness: some synthetic clicks on `↻` did not register and had
  to be repeated — cause not established (window activation consuming the first
  click, sub-glyph pointer precision, or both; the CSS hover box only appeared
  after nudging the pointer ~3 px). Which click landed is unambiguous in the
  daemon state (`last_changed_ms` moves only on the one that did), and no
  repeated click ever produced a second reload.
