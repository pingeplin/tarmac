# Doc card refresh manual QA checklist (spec 2609.0001, issue #89)

The [Q]-tagged scenarios S13–S20 the unit suites cannot cover: the React/Tauri
shell has no unit tests by design (only pure `kit/` logic and Rust are tested).
Run against `make run` with a fresh dev daemon (`make kill-daemon` first).

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`), since
a persistent installed daemon hijacks the dev app. This matters more here than for
any earlier QA sheet: every item below observes daemon-side behavior that does not
exist in an installed build, so a hijacked session fails S15–S20 for the wrong
reason and looks like a broken feature.

## Status: VERIFIED — 8/8 PASS (2026-09-05)

**S13–S20 all ran and all passed**, against this worktree's debug build driven
through the real UI. Every checked box below was observed on screen; screenshots
are named in each Observation line and live outside the repo in
`../tarmac-worktrees/qa89-scratch/`.

How the session was set up, since two details deviate from the sheet's literal
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
- Observation: `s13.png` / `s13_headers.png` — with the pointer parked on the
  zoom control, far from both cards, `probe.md` reads `¶ probe.md … ✚ now ↻ ✕`
  and `qa-magnify.html` reads `</> qa-magnify.html … ✚ now ↻ ⌐5 ✕`. Both cards
  were freshly opened, so the slot before `↻` held the fresh marker rather than a
  recency label; `s19_hdr.png` shows the same slot occupied by the real recency
  label (`¶ probe.md … ✎ 19s ↻ ✕`), so the full order is evidenced across the two.

## S14 — the control does not drag the card — PASS

- [x] Press on `↻` and drag: the card does **not** move.
- Observation: `s14.png` — pressed on `probe.md`'s `↻` and dragged ~85×60 screen
  px; the card did not move and its persisted tile stayed at `x=636, y=80`.
  Control run (so the result is not vacuous): the identical drag started from the
  header *background* moved the same card to `x=740, y=184`, i.e. the drag
  mechanism was live and only the `↻` suppressed it. Card dragged back afterwards.

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
- Observation: `s16.png` — board zoom 145%; the probe copy carries a per-load
  random `loadId` and a `setInterval` seconds-since-load counter. Before:
  `loadId=9948`, `aliveSec=53`, console badge 10 (its `lastChangedMs` had been
  populated by the S20 first click). After the click: `loadId=9948` unchanged,
  `aliveSec=85` (kept counting straight through), badge still 10, and the probe's
  measured box occupies exactly the same rectangle as before —
  (2406,892)–(3404,1352), 998×460 device px. No reload, no resize.

## S17 — changed HTML card reloads and comes back at board zoom — PASS

Use `desktop/qa/magnify-probe.html` — it declares `tarmac-zoom`, so each load logs
a `zoom-mode declared=…` console line. Copy it outside the repo before editing so
the QA run does not dirty the worktree.

- [x] With that card at board zoom ≠ 1 made stale by the recipe above, click `↻`:
      it reloads (page-local state resets).
- [x] The console badge count goes **up** — the card is never unmounted, so the
      reload appends to the existing buffer rather than starting a fresh one.
      (It grows by **5**, not 1, because this probe emits five console lines per
      load — one report on load, the received-`zoom` line, and the re-measure it
      triggers. The sheet's "+1" assumed a one-line document; what matters, and
      what was observed, is that the buffer *continued* from 5 to 10 instead of
      restarting at 5.)
- [x] The document comes back at the current board zoom, **not** at 1/K (the #99
      shape).
- Observation: `s17_before.png` → `s17.png`. Board zoom 145%. Stale baseline
  confirmed: banner still `QA89 BANNER: BASELINE`, `loadId=6833`,
  `aliveSec=650`, badge 5, no recency label, while the file on disk already read
  `EDIT-1` and the registry still held the pre-edit mtime. After the click: banner
  `QA89 BANNER: EDIT-1`, `loadId=2197`, `aliveSec=8` (page state reset), badge
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
- Observation: `s18_before.png` → `s18.png` — `probe.md`, unmodified, mtime ~15
  minutes old, card scrolled to sections 02–04. After the click the two captures
  are pixel-identical apart from the `↻`'s own hover box: same paragraphs, same
  scroll offset, no label appears, no spinner. Not vacuous: the click really
  reached the daemon — the doc's `last_changed_ms` went from `null` to
  `1788565209578` (the file's true mtime) in `state.json` at that moment; it
  simply matched what the app already had, so nothing rendered.

## S19 — the recency label shows the edit's age, not the click's — PASS

- [x] With a markdown card made stale by the recipe above, wait ~10 s after the
      edit (inside the 30 s window). Beforehand the header carries no recency
      label for that edit.
- [x] Click `↻`: the header shows `✎ Ns` where **N is the age of the edit (≈10 s),
      not `✎ 1s`** — the label is stamped from the file's real mtime, never from
      the click.
- Observation: `s19.png` / `s19_hdr.png`. Edit written at epoch 1788569051.44
  while board-1 was active (dropped by the watcher — registry still held
  1788568868835); board switched back; header carried **no** recency label.
  Clicked ≈9 s after the edit and the header immediately read **`✎ 9s`** — not
  `✎ 1s`. `s19.png`, captured at epoch 1788569070 (19 s after the edit), shows
  `✎ 19s`, i.e. the label keeps counting from the file's real mtime rather than
  from the moment of the click. Registry moved to `1788569051444`, the file's
  true mtime.

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
- Observation: `s20_first.png` (first click) and `s20.png` (second click). Card
  opened minutes earlier and never edited — `last_changed_ms` was `null` in
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
  the run was the harness: synthetic clicks that arrived while the window was not
  key were swallowed by macOS window activation and had to be repeated. Every
  repeat is visible in the daemon state (`last_changed_ms` moves only on the click
  that landed), and no repeated click ever produced a second reload.
