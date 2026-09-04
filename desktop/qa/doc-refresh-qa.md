# Doc card refresh manual QA checklist (spec 2609.0001, issue #89)

The [Q]-tagged scenarios S13–S20 the unit suites cannot cover: the React/Tauri
shell has no unit tests by design (only pure `kit/` logic and Rust are tested).
Run against `make run` with a fresh dev daemon (`make kill-daemon` first).

**CAUTION:** Kill any installed `tarmacd` before testing (`pkill tarmacd`), since
a persistent installed daemon hijacks the dev app. This matters more here than for
any earlier QA sheet: every item below observes daemon-side behavior that does not
exist in an installed build, so a hijacked session fails S15–S20 for the wrong
reason and looks like a broken feature.

## Status: NOT VERIFIED (2026-09-04)

**None of S13–S20 has been run.** The implementing agent could not launch the
dev app from this worktree: another checkout's Vite dev server held port 1420,
and killing a process it did not start was out of scope. Every box below is
therefore unchecked and every observation line is empty — not because the
behavior failed, but because it was never observed. Whoever runs this sheet
should fill in the observation lines and flip the status.

Automated coverage that does exist, for context on what is and is not still open:
`core/crates/tarmacd/tests/doc_refresh_integration.rs` (S3–S10, S21, S22 — the whole
daemon contract, including the watcher-missed-it case) and the `cardSrcUrl` purity
guard S11 in `desktop/src/kit/docKind.test.ts`. What is unverified is strictly the
UI shell: the control's presence, its drag behavior, and the on-screen result of a
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

## S13 — the control is present on both card kinds

- [ ] A markdown doc card shows `↻` in its header without hovering.
- [ ] A live HTML card shows it too.
- [ ] Order is recency label → `↻` → console badge (when present) → `✕`.
- Observation:

## S14 — the control does not drag the card

- [ ] Press on `↻` and drag: the card does **not** move.
- Observation:

## S15 — markdown refresh, scroll preserved (the #89 user story)

- [ ] With a markdown card made stale by the recipe above and scrolled partway
      down, click `↻`: the **new** content renders (verifiably the edited bytes,
      not the pre-edit ones).
- [ ] The scroll position is preserved — no jump to the top.
- Observation:

## S16 — unchanged HTML card is not reloaded

Precondition: the card's `lastChangedMs` is already populated (it has taken at
least one `file_event` — a prior edit or a prior refresh). S20 covers the
un-populated card, which behaves differently on purpose.

- [ ] With a magnify HTML card at board zoom ≠ 1 whose file has **not** changed,
      click `↻`: the document does **not** reload (page-local state such as a
      running counter survives).
- [ ] The card's rendered size does not change.
- Observation:

## S17 — changed HTML card reloads and comes back at board zoom

Use `desktop/qa/magnify-probe.html` — it declares `tarmac-zoom`, so each load logs
a `zoom-mode declared=…` console line. Copy it outside the repo before editing so
the QA run does not dirty the worktree.

- [ ] With that card at board zoom ≠ 1 made stale by the recipe above, click `↻`:
      it reloads (page-local state resets).
- [ ] The console badge count goes **up by one** — the card is never unmounted, so
      the reload appends a second zoom-mode line rather than starting a fresh
      buffer.
- [ ] The document comes back at the current board zoom, **not** at 1/K (the #99
      shape).
- Observation:

## S18 — an unchanged, stale-dated refresh is invisible

- [ ] Click `↻` on an unchanged doc older than the 30 s recency window (a markdown
      card, or an HTML card whose `lastChangedMs` is already populated): nothing
      visible happens — no spinner, no synthetic "just refreshed" label.
- [ ] On a markdown card scrolled partway down, neither the rendered content nor
      the scroll position moves.
- Observation:

## S19 — the recency label shows the edit's age, not the click's

- [ ] With a markdown card made stale by the recipe above, wait ~10 s after the
      edit (inside the 30 s window). Beforehand the header carries no recency
      label for that edit.
- [ ] Click `↻`: the header shows `✎ Ns` where **N is the age of the edit (≈10 s),
      not `✎ 1s`** — the label is stamped from the file's real mtime, never from
      the click.
- Observation:

## S20 — first refresh of a never-changed HTML card reloads once

This is the accepted one-time-reload trade-off (spec Open Question 1) made
observable. A freshly opened card has no `lastChangedMs`, so its iframe sits at
`?v=0` until the first `file_event` populates it.

- [ ] With a magnify HTML card freshly opened and never changed since, at board
      zoom ≠ 1, click `↻` **once**: the document reloads even though the file did
      not change (page-local state resets, console badge count +1).
- [ ] It comes back at the current board zoom, **not** at 1/K. If it lands at 1/K
      that is the #99 shape and a blocker, not an accepted trade-off.
- [ ] Click `↻` a **second** time with still no edit: nothing reloads (page-local
      state survives).
- Observation:
